module ExternalShares
  class ItemScope
    def initialize(external_share:)
      @external_share = external_share
      @organization = external_share.organization
    end

    def roots
      valid_items(@external_share.drive_items.order(:id))
    end

    def shared_root_ids
      root_items.pluck(:id)
    end

    def visible_items(parent_id: nil)
      if parent_id.present?
        parent = find_directory(parent_id)
        return DriveItem.none if parent.blank?

        children_of(parent.id)
      elsif @external_share.snapshot?
        snapshot_root_items
      else
        dynamic_root_items
      end
    end

    def all_visible_items
      visible_file_or_directory_scope.order(:item_type, :name, :id)
    end

    def find_item(id)
      visible_file_or_directory_scope.find_by(id: id)
    end

    def find_directory(id)
      visible_file_or_directory_scope.directory.find_by(id: id)
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

    def snapshot_root_items
      scope = visible_file_or_directory_scope.includes(:parent)
      roots = root_items
      file_root_ids = roots.file.select(:id)
      directory_root_ids = roots.directory.select(:id)

      scope.where(id: file_root_ids)
        .or(scope.where(parent_id: directory_root_ids))
        .order(:item_type, :name, :id)
    end

    def dynamic_root_items
      scope = visible_file_or_directory_scope
      roots = root_items
      file_root_ids = roots.file.select(:id)
      directory_root_ids = roots.directory.select(:id)

      scope.where(id: file_root_ids)
        .or(scope.where(parent_id: directory_root_ids))
        .order(:item_type, :name, :id)
    end

    def children_of(parent_id)
      visible_file_or_directory_scope.where(parent_id: parent_id).order(:item_type, :name, :id)
    end

    def valid_items(scope)
      scope.where(organization_id: @organization.id, deleted_at: nil, purged_at: nil)
    end

    def root_items
      if @external_share.snapshot?
        scope = visible_file_or_directory_scope
        shared_ids = scope.select(:id)
        scope.where(parent_id: nil).or(scope.where.not(parent_id: shared_ids))
      else
        valid_items(@external_share.drive_items)
      end
    end

    def under_dynamic_root?(drive_item)
      DynamicTreeResolver.new(external_share: @external_share).item_ids.include?(drive_item.id)
    end
  end
end
