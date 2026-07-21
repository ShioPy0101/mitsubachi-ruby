module ExternalShares
  class ItemScope
    def initialize(external_share:)
      @external_share = external_share
      @organization = external_share.organization
    end

    def roots
      valid_items(@external_share.drive_items.order(:id))
    end

    def visible_items(parent_id: nil)
      if @external_share.snapshot?
        snapshot_items(parent_id:)
      else
        dynamic_items(parent_id:)
      end
    end

    def find_item(id)
      visible_file_or_directory_scope.find_by(id: id)
    end

    def downloadable_files
      visible_file_or_directory_scope.file.order(:id).to_a
    end

    def include?(drive_item)
      return false if drive_item.blank?
      return false unless drive_item.organization_id == @organization.id
      return false if drive_item.deleted_at.present?

      if @external_share.snapshot?
        @external_share.external_share_items.exists?(drive_item_id: drive_item.id)
      else
        under_dynamic_root?(drive_item)
      end
    end

    private

    def visible_file_or_directory_scope
      ids =
        if @external_share.snapshot?
          @external_share.external_share_items.select(:drive_item_id)
        else
          DynamicTreeResolver.new(external_share: @external_share).item_ids
        end

      @organization.drive_items.active.where(id: ids)
    end

    def snapshot_items(parent_id:)
      scope = visible_file_or_directory_scope.includes(:parent)
      root_ids = @external_share.external_share_items.select(:drive_item_id)
      if parent_id.present?
        scope.where(parent_id: parent_id)
      else
        scope.where(parent_id: nil).or(scope.where.not(parent_id: root_ids))
      end.order(:item_type, :name, :id)
    end

    def dynamic_items(parent_id:)
      resolver = DynamicTreeResolver.new(external_share: @external_share)
      scope = @organization.drive_items.active.where(id: resolver.item_ids)

      if parent_id.present?
        return DriveItem.none unless resolver.item_ids.include?(parent_id.to_i)

        scope.where(parent_id: parent_id)
      else
        scope.where(id: @external_share.external_share_items.select(:drive_item_id))
      end.order(:item_type, :name, :id)
    end

    def valid_items(scope)
      scope.where(organization_id: @organization.id, deleted_at: nil)
    end

    def under_dynamic_root?(drive_item)
      DynamicTreeResolver.new(external_share: @external_share).item_ids.include?(drive_item.id)
    end
  end
end
