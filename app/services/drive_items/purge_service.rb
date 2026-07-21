require "fileutils"
require "securerandom"

module DriveItems
  class PurgeService
    PurgedFile = Data.define(:result, :storage_path, :temporary_path)

    Result = Data.define(:success?, :status, :message) do
      def self.success(message)
        new(true, :ok, message)
      end

      def self.failure(status, message)
        new(false, status, message)
      end
    end

    def initialize(drive_item:)
      @drive_item = drive_item
    end

    def call
      result = nil
      storage_path = nil
      temporary_path = nil

      ActiveRecord::Base.transaction do
        @drive_item.lock!
        result =
          if @drive_item.deleted_at.blank?
            Result.failure(:unprocessable_content, "先にゴミ箱へ移動してください")
          elsif @drive_item.directory?
            purge_directory
          else
            purged_file = purge_file
            storage_path = purged_file.storage_path
            temporary_path = purged_file.temporary_path
            result = purged_file.result
            if result.success?
              detach_access_logs!
              @drive_item.destroy!
            end
            result
          end
      end

      cleanup_temporary_file(temporary_path) if result&.success?
      result
    rescue StandardError => error
      restore_storage_file(temporary_path, storage_path)
      Rails.logger.error("[drive_items.purge] failed drive_item_id=#{@drive_item.id} error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_content, "完全削除できませんでした")
    end

    private

    def purge_directory
      return Result.failure(:unprocessable_content, "空でないフォルダは完全削除できません") if @drive_item.children.exists?

      detach_access_logs!
      @drive_item.destroy!
      Result.success("フォルダを完全削除しました")
    end

    def purge_file
      storage_key = @drive_item.effective_storage_key
      return PurgedFile.new(Result.failure(:unprocessable_content, "保存先キーが不正です"), nil, nil) unless ::DriveItem.valid_storage_key?(storage_key)

      storage_path = verified_storage_path(storage_key)
      return PurgedFile.new(Result.failure(:unprocessable_content, "保存先パスが不正です"), nil, nil) if storage_path.nil?
      return PurgedFile.new(Result.failure(:not_found, "実ファイルが見つかりません"), nil, nil) unless purgeable_regular_file?(storage_path)

      temporary_path = temporary_storage_path(storage_path)
      FileUtils.mv(storage_path, temporary_path)
      PurgedFile.new(Result.success("ファイルを完全削除しました"), storage_path, temporary_path)
    end

    def verified_storage_path(storage_key)
      storage_root = ::DriveItem.storage_root.join("drive_items").expand_path
      storage_path = ::DriveItem.storage_root.join(::DriveItem.storage_relative_path_for(storage_key)).expand_path
      expected_path = storage_root.join(storage_key).expand_path

      return unless storage_path == expected_path
      return unless storage_path.to_s.start_with?("#{storage_root}#{File::SEPARATOR}")

      storage_path
    end

    def purgeable_regular_file?(storage_path)
      return false unless File.exist?(storage_path)
      return false if File.symlink?(storage_path)

      File.lstat(storage_path).file?
    end

    def temporary_storage_path(storage_path)
      storage_path.dirname.join("#{storage_path.basename}.purging-#{SecureRandom.uuid}")
    end

    def restore_storage_file(temporary_path, storage_path)
      return if temporary_path.blank? || storage_path.blank?
      return unless File.exist?(temporary_path)
      return if File.exist?(storage_path)

      FileUtils.mv(temporary_path, storage_path)
    end

    def cleanup_temporary_file(temporary_path)
      return if temporary_path.blank?

      File.delete(temporary_path.to_s)
    rescue Errno::ENOENT
      nil
    rescue StandardError => error
      Rails.logger.error(
        "[drive_items.purge] temporary cleanup failed " \
        "drive_item_id=#{@drive_item.id} temporary_path=#{temporary_path} " \
        "error=#{error.class}: #{error.message}"
      )
    end

    def detach_access_logs!
      @drive_item.drive_item_access_logs.update_all(drive_item_id: nil, updated_at: Time.current)
    end
  end
end
