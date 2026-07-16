require "fileutils"
require "securerandom"

module Admin
  module DriveItems
    class PurgeService
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
        ActiveRecord::Base.transaction do
          @drive_item.lock!
          result =
            if @drive_item.deleted_at.blank?
              Result.failure(:unprocessable_entity, "先にゴミ箱へ移動してください")
            elsif @drive_item.directory?
              purge_directory
            else
              purge_file
            end
        end
        result
      rescue StandardError => error
        Rails.logger.error("[admin.drive_items.purge] failed drive_item_id=#{@drive_item.id} error=#{error.class}: #{error.message}")
        Result.failure(:unprocessable_entity, "完全削除できませんでした")
      end

      private

      def purge_directory
        return Result.failure(:unprocessable_entity, "空でないフォルダは完全削除できません") if @drive_item.children.exists?

        detach_access_logs!
        @drive_item.destroy!
        Result.success("ファイルを完全削除しました")
      end

      def purge_file
        storage_key = @drive_item.effective_storage_key
        return Result.failure(:unprocessable_entity, "保存先キーが不正です") unless ::DriveItem.valid_storage_key?(storage_key)

        storage_path = verified_storage_path(storage_key)
        return Result.failure(:unprocessable_entity, "保存先パスが不正です") if storage_path.nil?
        return Result.failure(:not_found, "実ファイルが見つかりません") unless purgeable_regular_file?(storage_path)

        temporary_path = temporary_storage_path(storage_path)
        FileUtils.mv(storage_path, temporary_path)
        begin
          detach_access_logs!
          @drive_item.destroy!
          FileUtils.rm_f(temporary_path)
        rescue StandardError
          restore_storage_file(temporary_path, storage_path)
          raise
        end
        Result.success("ファイルを完全削除しました")
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
        return unless File.exist?(temporary_path)
        return if File.exist?(storage_path)

        FileUtils.mv(temporary_path, storage_path)
      end

      def detach_access_logs!
        @drive_item.drive_item_access_logs.update_all(drive_item_id: nil, updated_at: Time.current)
      end
    end
  end
end
