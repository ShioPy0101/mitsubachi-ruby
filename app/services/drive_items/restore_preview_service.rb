require "set"

module DriveItems
  class RestorePreviewService
    RESOLUTIONS = %w[rename purge_existing select_destination restore_to_root skip].freeze

    ResultItem = Data.define(
      :item,
      :restore_target,
      :restore_items,
      :conflict_type,
      :before,
      :after,
      :existing_item,
      :parent_exists,
      :children_count,
      :descendant_conflict_count
    )

    def initialize(organization:, drive_items:, resolutions: {})
      @organization = organization
      @drive_items = Array(drive_items)
      @resolutions = resolutions
    end

    def call
      restore_targets.flat_map { |target| preview_tree(target) }
    end

    def as_json
      items = call
      {
        items: items.map { |item| item_json(item) },
        summary: summary_json(items)
      }
    end

    private

    def restore_targets
      @drive_items
        .map { |drive_item| DriveItems::RestoreService.new(drive_item: drive_item).restore_target }
        .uniq(&:id)
    end

    def preview_tree(restore_target)
      restore_items = restore_items_for(restore_target)
      restore_item_ids = restore_items.map(&:id).to_set
      restore_items.map do |item|
        build_item(item, restore_target, restore_items, restore_item_ids)
      end
    end

    def build_item(item, restore_target, restore_items, restore_item_ids)
      parent = restored_parent_for(item, restore_item_ids)
      parent_exists = parent_available?(item, parent, restore_item_ids)
      resolution = resolution_for(item, parent_exists)
      destination_parent = destination_parent_for(item, parent, restore_item_ids, resolution)
      name_conflict_item = name_conflict_item_for(item, destination_parent, restore_item_ids)
      content_conflict_item = content_conflict_item_for(item, restore_item_ids)
      existing_item = name_conflict_item || content_conflict_item
      conflict_type = conflict_type(parent_exists:, name_conflict_item:, content_conflict_item:)
      after_name = after_name_for(item, destination_parent, resolution, name_conflict_item)
      restorable = restorable_after?(resolution, parent_exists, destination_parent, content_conflict_item)

      ResultItem.new(
        item,
        restore_target,
        restore_items,
        conflict_type,
        before_json(item, parent, parent_exists, name_conflict_item, content_conflict_item),
        after_json(item, destination_parent, resolution, after_name, restorable, existing_item),
        existing_item,
        parent_exists,
        restore_items.size - 1,
        0
      )
    end

    def restore_items_for(restore_target)
      DriveItems::RestoreService.new(drive_item: restore_target).restore_items
    end

    def restored_parent_for(item, restore_item_ids)
      return item.parent if item.parent_id.present?
      return nil if item.parent_id.blank?

      ::DriveItem.where(organization_id: @organization.id, id: item.parent_id).first
    end

    def parent_available?(item, parent, restore_item_ids)
      return true if item.parent_id.blank?
      return true if restore_item_ids.include?(item.parent_id)

      parent.present? && parent.directory? && parent.deleted_at.nil? && parent.purged_at.nil?
    end

    def destination_parent_for(item, parent, restore_item_ids, resolution)
      return nil if resolution == "restore_to_root"
      if resolution == "select_destination"
        destination_parent_id = @resolutions[item.id]&.fetch(:destination_parent_id, nil)
        return active_parent(destination_parent_id)
      end
      return nil if item.parent_id.blank?
      return parent if restore_item_ids.include?(item.parent_id)
      return parent if parent_available?(item, parent, restore_item_ids)

      nil
    end

    def name_conflict_item_for(item, destination_parent, restore_item_ids)
      ::DriveItem
        .active
        .where(
          organization_id: @organization.id,
          parent_id: destination_parent&.id,
          name: item.name,
          extension: item.extension
        )
        .where.not(id: restore_item_ids.to_a)
        .first
    end

    def content_conflict_item_for(item, restore_item_ids)
      return unless item.file?
      return if item.file_hash.blank?

      ::DriveItem
        .active
        .file
        .where(organization_id: @organization.id, file_hash: item.file_hash)
        .where.not(id: restore_item_ids.to_a)
        .includes(:parent, :owner_user)
        .order(created_at: :desc, id: :desc)
        .detect { |candidate| deleted_ancestor(candidate).nil? }
    end

    def resolution_for(item, parent_exists)
      requested = @resolutions[item.id]&.fetch(:resolution, nil).to_s
      return requested if RESOLUTIONS.include?(requested)
      return "restore_to_root" unless parent_exists

      "rename"
    end

    def conflict_type(parent_exists:, name_conflict_item:, content_conflict_item:)
      has_name_conflict = name_conflict_item.present?
      has_content_conflict = content_conflict_item.present?

      if !parent_exists && has_name_conflict
        "name_conflict_and_missing_parent"
      elsif !parent_exists && has_content_conflict
        "active_content_duplicate_and_missing_parent"
      elsif !parent_exists
        "missing_parent"
      elsif has_name_conflict
        "name_conflict"
      elsif has_content_conflict
        "active_content_duplicate"
      else
        "none"
      end
    end

    def after_name_for(item, destination_parent, resolution, name_conflict_item)
      return nil if resolution == "skip"
      return item.name unless name_conflict_item.present? && resolution == "rename"

      next_available_name(parent_id: destination_parent&.id, name: item.name, extension: item.extension)
    end

    def restorable_after?(resolution, parent_exists, destination_parent, content_conflict_item)
      return false if resolution == "skip"
      return false if content_conflict_item.present?
      return destination_parent.present? if resolution == "select_destination"
      return true if resolution == "restore_to_root"
      destination_parent.nil? ? parent_exists : true
    end

    def before_json(item, parent, parent_exists, name_conflict_item, content_conflict_item)
      {
        name: item.filename,
        parent_id: item.parent_id,
        parent_path: parent_path(parent, item.parent_id),
        state: "trashed",
        restorable: parent_exists && name_conflict_item.blank? && content_conflict_item.blank?,
        reason: reason_for(parent_exists, name_conflict_item, content_conflict_item)
      }
    end

    def after_json(item, destination_parent, resolution, after_name, restorable, existing_item)
      {
        name: display_filename(after_name, item.extension),
        parent_id: destination_parent&.id,
        parent_path: parent_path(destination_parent, destination_parent&.id),
        restorable: restorable,
        resolution: resolution,
        existing_item_will_be_purged: resolution == "purge_existing" && existing_item.present?,
        existing_item: existing_item_json(existing_item),
        state: restorable ? "active" : "skipped",
        impact: impact_for(resolution, existing_item, restorable)
      }
    end

    def reason_for(parent_exists, name_conflict_item, content_conflict_item)
      reasons = []
      reasons << "元の復元先フォルダは削除されています" unless parent_exists
      reasons << "復元先に同名のファイルまたはフォルダーがあります" if name_conflict_item.present?
      reasons << "組織内に同じ内容のファイルがあります" if content_conflict_item.present?
      reasons.presence&.join(" / ")
    end

    def impact_for(resolution, existing_item, restorable)
      return "この項目は復元されません" if resolution == "skip"
      return "同じ内容の有効なファイルがあるため復元できません" if existing_item.present? && !restorable
      if resolution == "purge_existing" && existing_item.present?
        return existing_item.directory? ? "既存のフォルダーと配下を完全削除します" : "既存の項目を完全削除します"
      end
      return "自動リネームして復元します" if resolution == "rename" && existing_item.present?
      return "共有ドライブのルートに復元します" if resolution == "restore_to_root"

      "既存項目への影響はありません"
    end

    def item_json(preview)
      {
        item_id: preview.item.id,
        item_type: preview.item.item_type,
        restore_target_id: preview.restore_target.id,
        conflict_type: preview.conflict_type,
        parent_exists: preview.parent_exists,
        existing_item_id: preview.existing_item&.id,
        existing_item_type: preview.existing_item&.item_type,
        recommended_resolution: recommended_resolution(preview),
        auto_renamed_name: preview.after[:resolution] == "rename" ? preview.after[:name] : nil,
        children_count: preview.children_count,
        descendant_conflict_count: preview.descendant_conflict_count,
        before: preview.before,
        after: preview.after
      }
    end

    def summary_json(items)
      restorable = items.count { |item| item.after[:restorable] }
      skipped = items.count { |item| item.after[:resolution] == "skip" || !item.after[:restorable] }
      conflicts = items.count { |item| item.conflict_type != "none" }
      {
        total_count: items.size,
        conflict_count: conflicts,
        restorable_count: restorable,
        skipped_count: skipped,
        rename_count: items.count { |item| item.after[:resolution] == "rename" && item.before[:name] != item.after[:name] },
        purge_existing_count: items.count { |item| item.after[:existing_item_will_be_purged] }
      }
    end

    def recommended_resolution(preview)
      return "restore_to_root" unless preview.parent_exists
      return "skip" if preview.conflict_type.include?("active_content_duplicate")
      return "rename" if preview.existing_item.present?

      "rename"
    end

    def parent_path(parent, original_parent_id)
      return "/共有ドライブ" if original_parent_id.blank?
      return "削除済み、または存在しません" if parent.nil? || parent.purged_at.present?

      names = []
      current = parent
      while current.present? && current.organization_id == @organization.id
        names.unshift(current.name)
        current = current.parent
      end
      "/共有ドライブ#{names.empty? ? "" : "/#{names.join("/")}" }"
    end

    def active_parent(parent_id)
      return nil if parent_id.blank?

      ::DriveItem.active.directory.where(organization_id: @organization.id, id: parent_id).first
    end

    def existing_item_json(item)
      return nil if item.nil?

      {
        id: item.id,
        item_type: item.item_type,
        name: item.filename,
        parent_path: parent_path(item.parent, item.parent_id),
        purge_note: item.directory? ? "既存のフォルダーを完全削除すると、配下のファイルも削除されます" : "完全削除後は元に戻せません"
      }
    end

    def deleted_ancestor(item)
      current = item.parent
      visited_ids = Set.new
      while current.present? && current.organization_id == @organization.id
        return current if current.deleted_at.present? || current.purged_at.present?
        return if visited_ids.include?(current.id)

        visited_ids << current.id
        current = current.parent
      end
    end

    def next_available_name(parent_id:, name:, extension:)
      existing_names = ::DriveItem
        .active
        .where(organization_id: @organization.id, parent_id:, extension:)
        .pluck(:name)
        .to_set
      return name unless existing_names.include?(name)

      index = 1
      loop do
        candidate = "#{name} (#{index})"
        return candidate unless existing_names.include?(candidate)

        index += 1
      end
    end

    def display_filename(name, extension)
      return nil if name.nil?
      extension.present? ? "#{name}.#{extension}" : name
    end
  end
end
