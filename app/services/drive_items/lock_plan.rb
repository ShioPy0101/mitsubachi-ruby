module DriveItems
  class LockPlan
    def initialize(organization:)
      @organization = organization
    end

    def lock_active_parent!(parent_id)
      return nil if parent_id.blank?

      parent = @organization.drive_items.active.directory.find(parent_id)
      lock_items_by_id!([ parent ])

      # active tree invariant は lock 後に再確認する。事前 SELECT と child save の間に
      # parent が trash/purge へ進んだ場合、この地点で作成を止める。
      raise ActiveRecord::RecordNotFound if parent.deleted_at.present? || parent.purged_at.present?

      parent
    end

    def lock_active_parent_with_items!(parent_id, items)
      parent = parent_id.present? ? @organization.drive_items.find(parent_id) : nil
      locked = lock_items_by_id!([ parent, *Array(items) ])
      return locked if parent.nil?

      # replace/restore 等で親と対象 item を同時に扱う場合も、DriveItem は意味役割ではなく
      # id 昇順で lock する。lock 後に parent の active directory 条件を再確認する。
      parent.reload
      raise ActiveRecord::RecordNotFound if parent.deleted_at.present? || parent.purged_at.present?
      raise ActiveRecord::RecordNotFound unless parent.directory?

      locked
    end

    def lock_items_by_id!(items)
      Array(items).compact.uniq(&:id).sort_by(&:id).each(&:lock!)
    end
  end
end
