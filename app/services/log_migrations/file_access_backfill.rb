module LogMigrations
  class FileAccessBackfill
    DEFAULT_BATCH_SIZE = 500
    ACCESS_TYPES = {
      "drive_item.preview" => "preview",
      "drive_item.download_folder" => "download_folder",
      "external_share.file_previewed" => "preview",
      "external_share.file_downloaded" => "download",
      "external_share.bulk_downloaded" => "bulk_download",
      "flower.file.downloaded" => "download",
      "flower.file_downloaded" => "download"
    }.freeze

    Result = Data.define(:processed_count, :inserted_count, :deduplicated_count, :removed_count)

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      counts = { processed: 0, inserted: 0, deduplicated: 0, removed: 0 }

      OperationLog.where(operation_type: ACCESS_TYPES.keys).in_batches(of: @batch_size) do |relation|
        relation.each { |operation_log| migrate!(operation_log, counts) }
      end

      Result.new(counts[:processed], counts[:inserted], counts[:deduplicated], counts[:removed])
    end

    private

    def migrate!(operation_log, counts)
      counts[:processed] += 1
      attributes = access_attributes(operation_log)

      OperationLog.transaction do
        if duplicate?(attributes)
          counts[:deduplicated] += 1
        else
          DriveItemAccessLog.create!(attributes)
          counts[:inserted] += 1
        end
        operation_log.destroy!
        counts[:removed] += 1
      end
    end

    def access_attributes(operation_log)
      drive_item = drive_item_for(operation_log)
      external_share = external_share_for(operation_log)
      actor_kind = actor_kind_for(operation_log, external_share)

      {
        actor_kind: actor_kind,
        user_id: actor_kind == "user" ? operation_log.actor_user_id : nil,
        external_share_id: actor_kind == "external_share" ? external_share&.id : nil,
        organization_id: operation_log.organization_id || drive_item&.organization_id || external_share&.organization_id,
        drive_item_id: drive_item&.id,
        action: ACCESS_TYPES.fetch(operation_log.operation_type),
        occurred_at: operation_log.occurred_at,
        ip_address: operation_log.ip_address.presence || "unknown",
        user_agent: operation_log.user_agent.to_s,
        request_id: operation_log.request_id.presence || "migration-operation-#{operation_log.id}",
        metadata: file_metadata(operation_log, drive_item)
      }
    end

    def duplicate?(attributes)
      scope = DriveItemAccessLog.where(
        organization_id: attributes.fetch(:organization_id),
        drive_item_id: attributes.fetch(:drive_item_id),
        action: attributes.fetch(:action)
      )

      if attributes.fetch(:request_id).present?
        return true if scope.exists?(request_id: attributes.fetch(:request_id))
      end

      scope
        .where(user_id: attributes.fetch(:user_id), external_share_id: attributes.fetch(:external_share_id))
        .where(occurred_at: (attributes.fetch(:occurred_at) - 5.seconds)..(attributes.fetch(:occurred_at) + 5.seconds))
        .exists?
    end

    def drive_item_for(operation_log)
      id = operation_log.target_id if operation_log.target_type == "DriveItem"
      id ||= operation_log.metadata.to_h["drive_item_id"]
      DriveItem.find_by(id: id)
    end

    def external_share_for(operation_log)
      return operation_log.actor_external_share if operation_log.actor_external_share_id.present?

      id = operation_log.metadata.to_h["external_share_id"]
      ExternalShare.find_by(id: id)
    end

    def actor_kind_for(operation_log, external_share)
      return "user" if operation_log.actor_user_id.present?
      return "external_share" if external_share.present?

      "anonymous"
    end

    def file_metadata(operation_log, drive_item)
      operation_log.metadata.to_h.slice("filename", "file_hash", "file_size", "content_type", "client_type", "target_count").merge(
        "filename" => operation_log.metadata.to_h["filename"].presence || drive_item&.filename,
        "file_hash" => operation_log.metadata.to_h["file_hash"].presence || drive_item&.file_hash,
        "file_size" => operation_log.metadata.to_h["file_size"].presence || drive_item&.file_size,
        "content_type" => operation_log.metadata.to_h["content_type"].presence || drive_item&.content_type
      ).compact
    end
  end
end
