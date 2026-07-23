module DriveItems
  class TreeCollector
    class OrganizationBoundaryError < StandardError; end
    class CycleError < StandardError; end

    def initialize(root:)
      @root = root
    end

    def call
      return [ @root ] unless @root.directory?

      items = [ @root ]
      parent_ids = [ @root.id ]
      visited_ids = { @root.id => true }

      while parent_ids.any?
        children = ::DriveItem.where(parent_id: parent_ids, purged_at: nil).order(:id).to_a
        raise OrganizationBoundaryError if children.any? { |child| child.organization_id != @root.organization_id }
        raise CycleError if children.any? { |child| visited_ids.key?(child.id) }

        items.concat(children)
        children.each { |child| visited_ids[child.id] = true }
        parent_ids = children.map(&:id)
      end

      items
    end
  end
end
