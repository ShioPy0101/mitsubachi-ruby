module DriveItems
  # 通常ユーザー向け DriveItem 取得を organization scope に閉じ込める query object。
  #
  # Controller ごとに DriveItem.find を使うと ID 指定で別 organization の存在が漏れるため、
  # 一覧・詳細・配信前取得はこの object を通して current organization の relation から始める。
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
      # 配信可否は「active な同一 organization の record が存在するか」でまず絞る。
      # storage_key や実ファイルの検証は認可後に DeliveryService へ委譲する。
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
