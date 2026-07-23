require "fileutils"

module DriveItems
  class BulkPurgeService
    StorageTarget = Data.define(:drive_item_id, :storage_key, :blob_path)

    Result = Data.define(:success?, :status, :message, :purged_count) do
      def self.success(count)
        new(true, :ok, "#{count}件を完全削除しました", count)
      end

      def self.failure(status, message)
        new(false, status, message, 0)
      end
    end

    def initialize(organization:, drive_item_ids:, actor_user:)
      @organization = organization
      @drive_item_ids = Array(drive_item_ids).map(&:to_i).uniq
      @actor_user = actor_user
    end

    def call
      return Result.failure(:unprocessable_content, "対象が指定されていません") if @drive_item_ids.empty?
      return Result.failure(:not_found, "完全削除対象が見つかりません") if selected_trashed_items.size != @drive_item_ids.size

      roots = normalized_roots
      return Result.failure(:not_found, "完全削除対象が見つかりません") if roots.empty?
      storage_targets = []
      result = nil

      ActiveRecord::Base.transaction do
        roots.each(&:lock!)
        items = roots.flat_map { |root| collect_items(root) }.uniq(&:id).sort_by(&:id)
        items.each(&:lock!)
        storage_targets = collect_storage_targets(items)
        mark_as_purged!(items)
        result = Result.success(roots.size)
      end

      delete_storage_targets(storage_targets)
      result
    rescue DriveItems::PurgeService::OrganizationBoundaryError => error
      Rails.logger.error("[drive_items.bulk_purge] invalid tree error=#{error.class} root_ids=#{roots&.map(&:id)&.join(",")}")
      Result.failure(:unprocessable_content, "完全削除できませんでした")
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("[drive_items.bulk_purge] failed error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_content, "完全削除できませんでした")
    end

    private

    def selected_trashed_items
      @selected_trashed_items ||= @organization.drive_items.trashed.where(id: @drive_item_ids).order(:id).to_a
    end

    def normalized_roots
      root_ids = selected_trashed_items.map { |item| item.trashed_by_ancestor_id.presence || item.id }.uniq
      @organization
        .drive_items
        .trashed
        .where(id: root_ids)
        .where("trashed_by_ancestor_id IS NULL OR trashed_by_ancestor_id = drive_items.id")
        .order(:id)
        .to_a
    end

    def collect_items(root)
      return [ root ] unless root.directory?

      items = [ root ]
      parent_ids = [ root.id ]
      visited_ids = { root.id => true }

      while parent_ids.any?
        children = children_scope(root, parent_ids).to_a
        if children.any? { |child| child.organization_id != @organization.id }
          raise DriveItems::PurgeService::OrganizationBoundaryError, "別組織の子要素を検出しました"
        end
        if children.any? { |child| visited_ids.key?(child.id) }
          raise DriveItems::PurgeService::OrganizationBoundaryError, "循環した親子関係を検出しました"
        end

        items.concat(children)
        children.each { |child| visited_ids[child.id] = true }
        parent_ids = children.map(&:id)
      end

      items
    end

    def children_scope(root, parent_ids)
      scope = @organization.drive_items.where(parent_id: parent_ids)
      return scope unless trash_unit_scoped?(root)

      scope.where(trashed_by_ancestor_id: trash_root_id(root), purged_at: nil)
    end

    def trash_unit_scoped?(root)
      root.trash_batch_id.present? || root.trashed_by_ancestor_id.present?
    end

    def trash_root_id(root)
      root.trashed_by_ancestor_id.presence || root.id
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

    def log_storage_failure(target, error)
      Rails.logger.error(
        "[drive_items.bulk_purge] storage deletion failed " \
        "drive_item_id=#{target.drive_item_id} storage_key=#{target.storage_key} " \
        "blob_path=#{target.blob_path} error_class=#{error.class} " \
        "error_message=#{error.message} backtrace=#{Array(error.backtrace).join(" | ")}"
      )
    end
  end
end
