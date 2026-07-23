module DriveItems
  class BulkPurgeService
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

      roots = normalized_roots
      return Result.failure(:not_found, "完全削除対象が見つかりません") if roots.empty?
      return Result.failure(:not_found, "完全削除対象が見つかりません") if roots.size != @drive_item_ids.size && selected_trashed_items.size != @drive_item_ids.size

      roots.each do |drive_item|
        result = DriveItems::PurgeService.new(drive_item:, actor_user: @actor_user).call
        return result unless result.success?
      end

      Result.success(roots.size)
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
  end
end
