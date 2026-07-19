module DriveItems
  class Resolve
    MAX_ITEMS = 100

    Result = Data.define(:success?, :status, :error_message, :items) do
      def self.success(items)
        new(true, :ok, nil, items)
      end

      def self.failure(status, error_message)
        new(false, status, error_message, [])
      end
    end

    def initialize(organization:, items:)
      @organization = organization
      @items = items
    end

    def call
      return Result.failure(:bad_request, "items は配列で指定してください") unless @items.is_a?(Array)
      return Result.failure(:unprocessable_entity, "items は最大#{MAX_ITEMS}件まで指定できます") if @items.size > MAX_ITEMS

      requested = @items.map { |item| normalize_item(item) }
      ids = requested.filter_map { |item| item[:id] if item[:valid] }.uniq
      drive_items_by_id = DriveItems::Query.new(organization: @organization).resolve(ids).index_by { |drive_item| drive_item.id.to_s }

      Result.success(
        requested.map do |item|
          next invalid_result(item) unless item[:valid]

          drive_item = drive_items_by_id[item[:id]]
          next not_found_result(item) if drive_item.nil?
          next deleted_result(drive_item) if drive_item.deleted_at.present?

          resolved_result(drive_item, item[:known_file_hash])
        end
      )
    end

    private

    def normalize_item(item)
      id = item.respond_to?(:[]) ? item[:id] || item["id"] : nil
      known_file_hash = item.respond_to?(:[]) ? item[:known_file_hash] || item["known_file_hash"] : nil
      return { id: id.to_s, known_file_hash: known_file_hash, valid: false } if id.blank? || id.to_s !~ /\A\d+\z/

      { id: id.to_s, known_file_hash: known_file_hash.to_s.presence, valid: true }
    end

    def invalid_result(item)
      { id: item[:id], status: "invalid" }
    end

    def not_found_result(item)
      { id: item[:id], status: "not_found" }
    end

    def deleted_result(drive_item)
      { id: drive_item.id.to_s, status: "deleted", updated_at: drive_item.updated_at }
    end

    def resolved_result(drive_item, known_file_hash)
      {
        id: drive_item.id.to_s,
        status: drive_item.file_hash.present? && drive_item.file_hash == known_file_hash ? "current" : "updated",
        file_hash: drive_item.file_hash,
        file_size: drive_item.file_size,
        content_type: drive_item.content_type,
        updated_at: drive_item.updated_at
      }
    end
  end
end
