module Flower
  module DriveItems
    class Show
      def initialize(organization:, id:)
        @organization = organization
        @id = id
      end

      def call
        @organization
          .drive_items
          .active
          .file
          .where("content_type LIKE 'image/%' OR content_type LIKE 'video/%'")
          .includes(:owner_user, :parent)
          .find_by(id: @id)
      end
    end
  end
end
