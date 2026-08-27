require "set"

module DriveItems
  class RestoreConflictService
    Conflict = Data.define(:item, :type, :existing_item, :relative_path)

    def initialize(organization:, restore_target:, restore_items:)
      @organization = organization
      @restore_target = restore_target
      @restore_items = Array(restore_items)
      @restore_item_ids = @restore_items.map(&:id).to_set
    end

    def call
      @restore_items.filter_map { |item| name_conflict_for(item) }
    end

    def as_json
      call.map { |conflict| conflict_json(conflict) }
    end

    private

    def name_conflict_for(item)
      existing_item = ::DriveItem
        .active
        .where(
          organization_id: @organization.id,
          parent_id: destination_parent_id_for(item),
          name: item.name,
          extension: item.extension
        )
        .where.not(id: @restore_item_ids.to_a)
        .first
      return if existing_item.nil?

      Conflict.new(item, "name_conflict", existing_item, relative_path_for(item))
    end

    def destination_parent_id_for(item)
      return item.parent_id unless @restore_item_ids.include?(item.parent_id)

      item.parent_id
    end

    def relative_path_for(item)
      names = [ item.filename ]
      current = item.parent
      visited_ids = Set.new

      while current.present? && current.organization_id == @organization.id
        break if visited_ids.include?(current.id)

        names.unshift(current.filename)
        break if current.id == @restore_target.id

        visited_ids << current.id
        current = current.parent
      end

      names.join("/")
    end

    def conflict_json(conflict)
      {
        item_id: conflict.item.id,
        relative_path: conflict.relative_path,
        conflict_type: conflict.type,
        existing_item: existing_item_json(conflict.existing_item)
      }
    end

    def existing_item_json(item)
      {
        id: item.id,
        item_type: item.item_type,
        name: item.filename,
        parent_id: item.parent_id,
        deleted_at: item.deleted_at&.iso8601,
        purged_at: item.purged_at&.iso8601
      }
    end
  end
end
