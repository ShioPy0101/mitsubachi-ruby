module DriveItems
  class TrashRootsQuery
    def initialize(organization:)
      @organization = organization
    end

    def call
      @organization
        .drive_items
        .trashed
        .includes(:owner_user, :parent)
        .where("trashed_by_ancestor_id IS NULL OR trashed_by_ancestor_id = drive_items.id")
        .order(deleted_at: :desc, id: :desc)
    end
  end
end
