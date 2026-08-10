module DriveItems
  class RestoreService
    Result = Data.define(:success?, :status, :message, :restore_target, :items) do
      def self.success(message:, restore_target:, items:)
        new(true, :ok, message, restore_target, items)
      end

      def self.failure(status, message, restore_target: nil)
        new(false, status, message, restore_target, [])
      end
    end

    def initialize(drive_item:)
      @drive_item = drive_item
    end

    def restore_target
      @restore_target ||= restore_target_for(@drive_item)
    end

    def restore_items
      @restore_items ||= restore_items_for(restore_target)
    end

    def call
      restore_target = self.restore_target

      ActiveRecord::Base.transaction do
        items = restore_items
        lock_plan.lock_items_by_id!([ restore_target, *items ])
        restore_target.reload
        raise ActiveRecord::RecordNotFound if restore_target.purged_at.present? || restore_target.deleted_at.blank?

        items.each do |item|
          item.reload
          next if item.purged_at.present?
          raise ActiveRecord::RecordInvalid, item if item.deleted_at.blank?

          item.update!(
            deleted_at: nil,
            trash_batch_id: nil,
            trashed_by_ancestor_id: nil
          )
        end

        Result.success(message: "ファイルまたはフォルダを復元しました", restore_target:, items:)
      end
    rescue ActiveRecord::RecordNotUnique => error
      record_failure(error)
      Rails.logger.error("[drive_items.restore] conflict error=#{error.class}: #{error.message}")
      Result.failure(:conflict, "復元先に競合する項目があります", restore_target: @drive_item)
    rescue ActiveRecord::ActiveRecordError => error
      record_failure(error)
      Rails.logger.error("[drive_items.restore] failed error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_content, "復元できませんでした", restore_target: @drive_item)
    end

    private

    def record_failure(error)
      SystemEvents::Recorder.record!(
        event_type: "storage.restore_failed",
        severity: "error",
        source: "storage",
        organization: @drive_item.organization,
        target: @drive_item,
        error: error
      )
    end

    def lock_plan
      @lock_plan ||= DriveItems::LockPlan.new(organization: @drive_item.organization)
    end

    def restore_target_for(drive_item)
      if drive_item.trashed_by_ancestor_id.present?
        candidate = ::DriveItem.where(
          organization_id: drive_item.organization_id,
          id: drive_item.trashed_by_ancestor_id,
          purged_at: nil
        ).first
        return candidate if candidate&.deleted_at.present?
      end

      top_deleted_ancestor(drive_item) || drive_item
    end

    def top_deleted_ancestor(drive_item)
      top = nil
      current = drive_item.parent

      while current.present? && current.organization_id == drive_item.organization_id
        top = current if current.deleted_at.present? && current.purged_at.nil?
        current = current.parent
      end

      top
    end

    def restore_items_for(restore_target)
      if restore_target.trash_batch_id.present?
        return ::DriveItem
          .where(
            organization_id: restore_target.organization_id,
            trash_batch_id: restore_target.trash_batch_id,
            purged_at: nil
          )
          .where("id = :id OR trashed_by_ancestor_id = :id", id: restore_target.id)
          .order(:id)
          .to_a
      end

      return [ restore_target ] unless restore_target.directory?

      DriveItems::TreeCollector
        .new(root: restore_target)
        .call
        .select { |item| item.deleted_at.present? && item.purged_at.nil? }
    end
  end
end
