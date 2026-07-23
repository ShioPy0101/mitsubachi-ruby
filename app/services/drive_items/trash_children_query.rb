module DriveItems
  class TrashChildrenQuery
    def initialize(organization:, parent_id:)
      @organization = organization
      @parent_id = parent_id
    end

    def call
      return ::DriveItem.none if parent.nil? || !parent.directory?

      root_id = parent.trashed_by_ancestor_id.presence || parent.id
      @organization
        .drive_items
        .trashed
        .includes(:owner_user, :parent)
        .where(parent_id: parent.id, trashed_by_ancestor_id: root_id)
        .order(item_type: :desc, name: :asc, id: :asc)
    end

    private

    def parent
      @parent ||= @organization.drive_items.trashed.find_by(id: @parent_id)
    end
  end
end
