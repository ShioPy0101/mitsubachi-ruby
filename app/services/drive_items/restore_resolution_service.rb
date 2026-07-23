module DriveItems
  class RestoreResolutionService
    Result = Data.define(:success?, :status, :message, :items, :preview) do
      def self.success(items:)
        new(true, :ok, "ファイルまたはフォルダを復元しました", items, nil)
      end

      def self.stale(preview:)
        new(false, :conflict, "確認後に復元先の状態が変更されました。内容を再確認してください", [], preview)
      end

      def self.failure(status, message)
        new(false, status, message, [], nil)
      end
    end

    def initialize(organization:, actor_user:, items:)
      @organization = organization
      @actor_user = actor_user
      @items = Array(items)
      @resolution_map = @items.index_by { |item| item.fetch(:item_id).to_i }
    end

    def call
      drive_items = @organization.drive_items.deleted.where(id: @resolution_map.keys).to_a
      return Result.failure(:not_found, "復元対象が見つかりません") if drive_items.size != @resolution_map.size

      preview = DriveItems::RestorePreviewService.new(
        organization: @organization,
        drive_items: drive_items,
        resolutions: resolution_options
      )
      preview_items = preview.call
      return Result.stale(preview: preview.as_json) unless current_preview_matches?(preview_items)

      restored_items = []
      ActiveRecord::Base.transaction do
        preview_items.each do |preview_item|
          next if preview_item.after[:resolution] == "skip"

          restore_item!(preview_item)
          restored_items << preview_item.item
        end
      end

      Result.success(items: restored_items)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("[drive_items.restore_resolution] failed error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_content, "復元できませんでした")
    end

    private

    def resolution_options
      @resolution_map.transform_values do |item|
        {
          resolution: item[:resolution].to_s,
          destination_parent_id: item[:destination_parent_id]
        }
      end
    end

    def current_preview_matches?(preview_items)
      preview_items.all? do |preview_item|
        expected = @resolution_map[preview_item.item.id]
        next true if expected.nil?

        expected[:resolution].to_s == preview_item.after[:resolution].to_s &&
          expected_name_matches?(expected, preview_item) &&
          expected_existing_matches?(expected, preview_item)
      end
    end

    def expected_name_matches?(expected, preview_item)
      return true if expected[:expected_name].blank?

      expected[:expected_name].to_s == preview_item.after[:name].to_s
    end

    def expected_existing_matches?(expected, preview_item)
      return true unless expected.key?(:expected_existing_item_id)

      expected[:expected_existing_item_id].presence&.to_i == preview_item.existing_item&.id
    end

    def restore_item!(preview_item)
      preview_item.item.lock!
      purge_existing_item!(preview_item.existing_item) if preview_item.after[:existing_item_will_be_purged]

      preview_item.item.update!(
        name: restored_name_without_extension(preview_item),
        parent_id: preview_item.after[:parent_id],
        deleted_at: nil,
        trash_batch_id: nil,
        trashed_by_ancestor_id: nil
      )
    end

    def purge_existing_item!(existing_item)
      return if existing_item.nil?

      existing_item.lock!
      items = existing_items_for_purge(existing_item)
      purged_at = Time.current
      items.each do |item|
        item.update!(
          deleted_at: item.deleted_at || purged_at,
          purged_at: purged_at,
          purged_by_user: @actor_user,
          trash_batch_id: nil,
          trashed_by_ancestor_id: nil
        )
      end
    end

    def existing_items_for_purge(existing_item)
      return [ existing_item ] unless existing_item.directory?

      DriveItems::TreeCollector.new(root: existing_item).call
    end

    def restored_name_without_extension(preview_item)
      after_name = preview_item.after[:name].to_s
      extension = preview_item.item.extension
      return after_name if extension.blank?

      after_name.delete_suffix(".#{extension}")
    end
  end
end
