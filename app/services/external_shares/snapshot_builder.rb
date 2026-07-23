module ExternalShares
  class SnapshotBuilder
    def initialize(organization:, roots:)
      @organization = organization
      @roots = roots
    end

    def item_ids
      ids = {}
      @roots.each { |root| collect(root, ids) }
      ids.keys
    end

    private

    def collect(drive_item, ids)
      return if ids[drive_item.id]
      return unless drive_item.organization_id == @organization.id
      return if drive_item.deleted_at.present? || drive_item.purged_at.present?

      ids[drive_item.id] = true
      return unless drive_item.directory?

      drive_item.children.active.order(:id).find_each do |child|
        collect(child, ids)
      end
    end
  end
end
