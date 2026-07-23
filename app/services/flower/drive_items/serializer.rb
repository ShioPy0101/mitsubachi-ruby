module Flower
  module DriveItems
    class Serializer
      def initialize(drive_item)
        @drive_item = drive_item
      end

      def list_json
        {
          id: @drive_item.id.to_s,
          name: @drive_item.name,
          extension: @drive_item.extension,
          display_name: @drive_item.filename,
          content_type: @drive_item.content_type,
          file_size: @drive_item.file_size,
          sha256: normalized_sha256,
          updated_at: @drive_item.updated_at&.iso8601(3),
          parent_id: @drive_item.parent_id&.to_s
        }
      end

      def detail_json
        list_json.merge(
          download: {
            available: @drive_item.file? && @drive_item.deleted_at.nil? && @drive_item.purged_at.nil?
          }
        )
      end

      private

      def normalized_sha256
        value = @drive_item.file_hash.to_s.downcase
        value = value.delete_prefix("sha256:")
        return if value.blank?
        return unless value.match?(/\A[0-9a-f]{64}\z/)

        "sha256:#{value}"
      end
    end
  end
end
