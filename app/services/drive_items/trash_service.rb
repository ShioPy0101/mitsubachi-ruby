require "securerandom"

module DriveItems
  class TrashService
    Result = Data.define(:success?, :status, :message, :deleted_at, :roots) do
      def self.success(message:, deleted_at:, roots:)
        new(true, :ok, message, deleted_at, roots)
      end

      def self.failure(status, message)
        new(false, status, message, nil, [])
      end
    end

    def initialize(drive_items:)
      @drive_items = Array(drive_items).uniq(&:id).sort_by(&:id)
    end

    def call
      deleted_at = Time.current

      ActiveRecord::Base.transaction do
        @drive_items.each do |drive_item|
          trash_tree!(drive_item, deleted_at)
        end
      end

      Result.success(message: "ファイルまたはフォルダをゴミ箱に移動しました", deleted_at:, roots: @drive_items)
    rescue DriveItems::TreeCollector::OrganizationBoundaryError, DriveItems::TreeCollector::CycleError => error
      record_failure(error)
      Rails.logger.error("[drive_items.trash] invalid tree error=#{error.class} root_ids=#{@drive_items.map(&:id).join(",")}")
      Result.failure(:unprocessable_content, "ゴミ箱へ移動できませんでした")
    rescue ActiveRecord::ActiveRecordError => error
      record_failure(error)
      Rails.logger.error("[drive_items.trash] failed error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_content, "ゴミ箱へ移動できませんでした")
    end

    private

    def record_failure(error)
      SystemEvents::Recorder.record!(
        event_type: "storage.trash_failed",
        severity: "error",
        source: "storage",
        organization: @drive_items.first&.organization,
        target: @drive_items.first,
        error: error,
        metadata: { root_ids: @drive_items.map(&:id) }
      )
    end

    def trash_tree!(drive_item, deleted_at)
      # subtree 収集を lock 前の一度きりにすると、parent lock 待ち中に commit された
      # child が trash 対象から漏れる。LockPlan 側で再収集まで含めて扱い、
      # active tree invariant を trash 操作側からも守る。
      items = DriveItems::LockPlan.new(organization: drive_item.organization).lock_tree_stably!(drive_item)

      batch_id = SecureRandom.uuid
      items.each do |item|
        item.reload
        next if item.deleted_at.present? || item.purged_at.present?

        item.update!(
          deleted_at: deleted_at,
          trash_batch_id: batch_id,
          trashed_by_ancestor_id: drive_item.id
        )
      end
    end
  end
end
