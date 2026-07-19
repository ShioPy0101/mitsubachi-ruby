module Flower
  module DriveItems
    class List
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      Result = Data.define(:items, :next_cursor)

      def initialize(organization:, params:)
        @organization = organization
        @params = params
      end

      def call
        limit = requested_limit
        scope = media_files
        scope = apply_query(scope, @params[:query]) if @params[:query].present?
        scope = scope.where(parent_id: @params[:parent_id]) if @params.key?(:parent_id)
        scope = scope.where("drive_items.id > ?", decoded_cursor) if decoded_cursor

        items = scope.order(id: :asc).limit(limit + 1).to_a
        next_cursor = items.size > limit ? encode_cursor(items.pop.id) : nil
        Result.new(items, next_cursor)
      end

      private

      def media_files
        @organization
          .drive_items
          .active
          .file
          .includes(:owner_user, :parent)
          .where("content_type LIKE 'image/%' OR content_type LIKE 'video/%'")
      end

      def apply_query(scope, query)
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip.downcase)}%"
        scope.where(
          "LOWER(name) LIKE :pattern OR LOWER(extension) LIKE :pattern OR LOWER(content_type) LIKE :pattern",
          pattern: pattern
        )
      end

      def requested_limit
        raw = @params[:limit].presence || DEFAULT_LIMIT
        raw.to_i.clamp(1, MAX_LIMIT)
      end

      def decoded_cursor
        cursor = @params[:cursor].to_s
        return if cursor.blank?

        decoded = Base64.urlsafe_decode64(cursor)
        Integer(decoded)
      rescue ArgumentError
        nil
      end

      def encode_cursor(id)
        Base64.urlsafe_encode64(id.to_s, padding: false)
      end
    end
  end
end
