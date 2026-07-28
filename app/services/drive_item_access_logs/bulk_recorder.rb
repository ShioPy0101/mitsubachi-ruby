module DriveItemAccessLogs
  class BulkRecorder
    def initialize(organization:, drive_items:, action:, request:, user: nil, external_share: nil, metadata: {})
      @organization = organization
      @drive_items = drive_items
      @action = action.to_s
      @request = request
      @user = user
      @external_share = external_share
      @metadata = metadata
    end

    def call
      now = Time.current
      batch_id = @metadata[:batch_id].presence || @request.request_id.to_s
      rows = @drive_items.map do |drive_item|
        {
          actor_kind: actor_kind,
          organization_id: @organization.id,
          user_id: @user&.id,
          external_share_id: @external_share&.id,
          drive_item_id: drive_item.id,
          action: @action,
          occurred_at: now,
          ip_address: @request.remote_ip,
          user_agent: @request.user_agent.to_s,
          request_id: @request.request_id.to_s,
          batch_id: batch_id,
          metadata: file_metadata(drive_item).merge(@metadata.except(:batch_id)),
          created_at: now,
          updated_at: now
        }
      end
      DriveItemAccessLog.insert_all!(rows) if rows.any?
      true
    rescue StandardError => error
      Rails.logger.error(
        "[drive_item_access_logs.bulk_recorder] failed organization_id=#{@organization.id} action=#{@action} " \
        "request_id=#{@request.request_id} error=#{error.class}: #{error.message}"
      )
      false
    end

    private

    def actor_kind
      return "user" if @user.present?
      return "external_share" if @external_share.present?

      "anonymous"
    end

    def file_metadata(drive_item)
      {
        filename: drive_item.filename,
        file_hash: drive_item.file_hash,
        file_size: drive_item.file_size,
        content_type: drive_item.content_type
      }
    end
  end
end
