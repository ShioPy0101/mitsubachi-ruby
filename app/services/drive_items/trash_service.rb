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
      @drive_items = Array(drive_items).uniq(&:id)
    end

    def call
      deleted_at = Time.current

      ActiveRecord::Base.transaction do
        @drive_items.each do |drive_item|
          drive_item.lock!
          trash_tree!(drive_item, deleted_at)
        end
      end

      Result.success(message: "ファイルまたはフォルダをゴミ箱に移動しました", deleted_at:, roots: @drive_items)
    rescue DriveItems::TreeCollector::OrganizationBoundaryError, DriveItems::TreeCollector::CycleError => error
      Rails.logger.error("[drive_items.trash] invalid tree error=#{error.class} root_ids=#{@drive_items.map(&:id).join(",")}")
      Result.failure(:unprocessable_content, "ゴミ箱へ移動できませんでした")
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("[drive_items.trash] failed error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_content, "ゴミ箱へ移動できませんでした")
    end

    private

    def trash_tree!(drive_item, deleted_at)
      items = DriveItems::TreeCollector.new(root: drive_item).call
      items.each(&:lock!)

      batch_id = SecureRandom.uuid
      items.each do |item|
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
