module ExternalShares
  class DynamicTreeResolver
    def initialize(external_share:)
      @external_share = external_share
      @organization = external_share.organization
    end

    def item_ids
      ids = {}
      roots.each { |root| collect(root, ids) }
      ids.keys
    end

    private

    def roots
      @external_share.drive_items.active.where(organization_id: @organization.id).order(:id)
    end

    def collect(drive_item, ids)
      return if ids[drive_item.id]

      ids[drive_item.id] = true
      drive_item.children.active.where(organization_id: @organization.id).order(:id).find_each do |child|
        collect(child, ids)
      end
    end
  end
end
