require "fileutils"

module DriveItems
  class PurgeService
    StorageTarget = Data.define(:drive_item_id, :storage_key, :blob_path)

    Result = Data.define(:success?, :status, :message) do
      def self.success(message)
        new(true, :ok, message)
      end

      def self.failure(status, message)
        new(false, status, message)
      end
    end

    class OrganizationBoundaryError < StandardError; end

    def initialize(drive_item:, actor_user: nil)
      @drive_item = drive_item
      @actor_user = actor_user
    end

    def call
      storage_targets = []
      result = ActiveRecord::Base.transaction do
        @drive_item.lock!
        next Result.failure(:unprocessable_content, "先にゴミ箱へ移動してください") if @drive_item.deleted_at.blank?

        items = collect_items
        items.each(&:lock!)
        storage_targets = collect_storage_targets(items)
        mark_as_purged!(items)

        Result.success(@drive_item.directory? ? "フォルダを完全削除しました" : "ファイルを完全削除しました")
      end

      delete_storage_targets(storage_targets) if result.success?
      result
    rescue StandardError => error
      log_database_failure(error)
      Result.failure(:unprocessable_content, "完全削除できませんでした")
    end

    private

    def collect_items
      return [ @drive_item ] unless @drive_item.directory?

      items = [ @drive_item ]
      parent_ids = [ @drive_item.id ]
      visited_ids = { @drive_item.id => true }

      while parent_ids.any?
        children = ::DriveItem.where(parent_id: parent_ids).to_a
        if children.any? { |child| child.organization_id != @drive_item.organization_id }
          raise OrganizationBoundaryError, "別組織の子要素を検出しました"
        end
        if children.any? { |child| visited_ids.key?(child.id) }
          raise OrganizationBoundaryError, "循環した親子関係を検出しました"
        end

        items.concat(children)
        children.each { |child| visited_ids[child.id] = true }
        parent_ids = children.map(&:id)
      end

      items
    end

    def collect_storage_targets(items)
      items.filter_map do |item|
        next unless item.file?

        StorageTarget.new(item.id, item.effective_storage_key, item.blob_path)
      end.uniq { |target| target.storage_key.presence || target.blob_path }
    end

    def mark_as_purged!(items)
      purged_at = Time.current
      items.each do |item|
        item.update!(
          purged_at: purged_at,
          deleted_at: item.deleted_at || purged_at,
          purged_by_user: @actor_user,
          trash_batch_id: nil,
          trashed_by_ancestor_id: nil,
          storage_key: nil,
          blob_path: nil
        )
      end
    end

    def delete_storage_targets(targets)
      targets.each do |target|
        next if referenced_by_not_purged_item?(target)

        delete_storage_target(target)
      rescue StandardError => error
        log_storage_failure(target, error)
      end
    end

    def referenced_by_not_purged_item?(target)
      # ストレージ実体は組織をまたいで共有される可能性もあるため、参照確認では組織を限定しない。
      scope = ::DriveItem.not_purged
      conditions = []
      conditions << scope.where(storage_key: target.storage_key) if target.storage_key.present?
      conditions << scope.where(blob_path: target.blob_path) if target.blob_path.present?
      conditions.any?(&:exists?)
    end

    def delete_storage_target(target)
      storage_key = target.storage_key.presence || storage_key_from_blob_path(target.blob_path)
      raise ArgumentError, "保存先キーが不正です" unless ::DriveItem.valid_storage_key?(storage_key)

      storage_path = verified_storage_path(storage_key)
      raise ArgumentError, "保存先パスが不正です" if storage_path.nil?
      return unless File.exist?(storage_path)
      raise ArgumentError, "シンボリックリンクは削除できません" if File.symlink?(storage_path)
      raise ArgumentError, "通常ファイルではありません" unless File.lstat(storage_path).file?

      FileUtils.rm_f(storage_path)
    end

    def storage_key_from_blob_path(blob_path)
      return if blob_path.blank?

      blob_path.to_s.delete_prefix("drive_items/")
    end

    def verified_storage_path(storage_key)
      storage_root = ::DriveItem.storage_root.join("drive_items").expand_path
      storage_path = storage_root.join(storage_key).expand_path
      return unless storage_path.parent == storage_root

      storage_path
    end

    def log_database_failure(error)
      Rails.logger.error(
        "[drive_items.purge] failed root_drive_item_id=#{@drive_item.id} " \
        "error_class=#{error.class} error_message=#{error.message} " \
        "backtrace=#{Array(error.backtrace).join(" | ")}"
      )
    end

    def log_storage_failure(target, error)
      Rails.logger.error(
        "[drive_items.purge] storage deletion failed " \
        "root_drive_item_id=#{@drive_item.id} drive_item_id=#{target.drive_item_id} " \
        "storage_key=#{target.storage_key} blob_path=#{target.blob_path} " \
        "error_class=#{error.class} error_message=#{error.message} " \
        "backtrace=#{Array(error.backtrace).join(" | ")}"
      )
    end
  end
end
