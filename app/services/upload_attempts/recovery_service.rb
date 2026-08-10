require "fileutils"

module UploadAttempts
  # UploadAttempt は DB と filesystem の境界をまたぐため、process crash 後には
  # 「state だけ」では復旧先を決められない。ここでは DriveItem と staging/final の
  # 実体を確認し、UploadStateMachine::CRASH_MATRIX に存在する event だけを実行する。
  class RecoveryService
    Result = Data.define(:state, :action, :attempt)

    def initialize(upload_attempt:)
      @upload_attempt = upload_attempt
    end

    def call
      @upload_attempt.with_lock do
        rule = matching_rule
        return Result.new(@upload_attempt.state_name, :noop, @upload_attempt) if rule.nil? || rule[:event].nil?

        apply_rule!(rule)
        Result.new(@upload_attempt.state_name, rule.fetch(:recovery_action), @upload_attempt)
      end
    end

    private

    def matching_rule
      UploadStateMachine::CRASH_MATRIX.find do |rule|
        rule.fetch(:observed_state) == @upload_attempt.state_name &&
          rule.fetch(:filesystem) == filesystem_state &&
          rule.fetch(:db) == db_state
      end
    end

    def apply_rule!(rule)
      case rule.fetch(:recovery_action)
      when :publish_staging
        @upload_attempt.transition!(rule.fetch(:event))
        publish_staging!
        @upload_attempt.transition!(:publish_succeeded)
        return
      when :cleanup_staging, :cleanup_and_restart
        cleanup_staging!
      when :cleanup_staging_and_mark_completed
        cleanup_staging!
      when :compensate_db
        compensate_unpublished_drive_item!
      end

      @upload_attempt.transition!(rule.fetch(:event))
    end

    def publish_staging!
      staging_path = @upload_attempt.staging_path
      final_path = @upload_attempt.storage_path
      raise Errno::ENOENT, "staging file is missing" if staging_path.blank? || !File.file?(staging_path)
      raise ArgumentError, "storage key is missing" if final_path.blank?

      FileUtils.mkdir_p(final_path.dirname)
      File.rename(staging_path, final_path)
    end

    def filesystem_state
      staging = @upload_attempt.staging_file_exists?
      final = @upload_attempt.final_file_exists?

      if staging && final
        :staging_and_final_present
      elsif staging
        @upload_attempt.state_name == :staging ? :partial_staging_no_final : :staging_complete_no_final
      elsif final
        :no_staging_final_present
      else
        :no_staging_no_final
      end
    end

    def db_state
      @upload_attempt.drive_item_id.present? ? :drive_item_present : :drive_item_absent
    end

    def cleanup_staging!
      path = @upload_attempt.staging_path
      return if path.blank?

      FileUtils.rm_f(path)
    end

    def compensate_unpublished_drive_item!
      drive_item = @upload_attempt.drive_item
      return if drive_item.nil? || drive_item.purged_at.present?

      drive_item.update!(
        deleted_at: Time.current,
        purged_at: Time.current,
        purged_by_user: @upload_attempt.user,
        storage_key: nil,
        blob_path: nil
      )
    end
  end
end
