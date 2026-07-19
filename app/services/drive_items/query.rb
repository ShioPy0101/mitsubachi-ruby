module DriveItems
  class Query
    def initialize(organization:)
      @organization = organization
    end

    def active
      @organization.drive_items.active
    end

    def list(parent_id:, query: nil)
      scope = active.includes(:owner_user, :parent).where(parent_id: normalized_parent_id(parent_id))
      scope = apply_search(scope, query) if query.present?
      scope.order(item_type: :desc, name: :asc)
    end

    def find_active(id)
      active.includes(:owner_user, :parent).find_by(id: id)
    end

    def find_deliverable(id)
      active.find_by(id: id)
    end

    def resolve(ids)
      @organization.drive_items.includes(:owner_user, :parent).where(id: ids)
    end

    private

    def normalized_parent_id(parent_id)
      parent_id.present? ? parent_id.to_i : nil
    end

    def apply_search(scope, query)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip.downcase)}%"
      scope.joins("LEFT JOIN users owner_users ON owner_users.id = drive_items.owner_user_id").where(
        "LOWER(drive_items.name) LIKE :pattern OR " \
        "LOWER(COALESCE(drive_items.extension, '')) LIKE :pattern OR " \
        "LOWER(COALESCE(owner_users.display_name, owner_users.name, '')) LIKE :pattern",
        pattern: pattern
      )
    end
  end
end
