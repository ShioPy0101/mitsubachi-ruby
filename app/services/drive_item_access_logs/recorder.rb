module DriveItemAccessLogs
  class Recorder
    Result = Data.define(:success?, :error_message) do
      def self.success
        new(true, nil)
      end

      def self.failure(error_message)
        new(false, error_message)
      end
    end

    STREAM_DEDUP_WINDOW = 5.minutes

    def initialize(organization:, user: nil, external_share: nil, drive_item:, action:, request:, metadata: {})
      @organization = organization
      @user = user
      @external_share = external_share
      @drive_item = drive_item
      @action = action.to_s
      @request = request
      @metadata = metadata
    end

    def call
      return Result.success if skip_stream_log?

      DriveItemAccessLog.create!(
        organization: @organization,
        actor_kind: actor_kind,
        user: @user,
        external_share: @external_share,
        drive_item: @drive_item,
        action: @action,
        occurred_at: Time.current,
        ip_address: @request.remote_ip,
        user_agent: @request.user_agent.to_s,
        request_id: @request.request_id.to_s,
        batch_id: @metadata[:batch_id],
        metadata: metadata.except(:batch_id)
      )

      Result.success
    rescue StandardError => error
      Rails.logger.error(
        "[drive_item_access_logs.recorder] failed organization_id=#{@organization.id} user_id=#{@user&.id} " \
        "drive_item_id=#{@drive_item.id} action=#{@action} request_id=#{@request.request_id} " \
        "error=#{error.class}: #{error.message}"
      )
      Result.failure("ファイルアクセス履歴の保存に失敗しました")
    end

    private

    def skip_stream_log?
      return false unless @action == "stream"

      DriveItemAccessLog.recent_stream_for(
        organization: @organization,
        user: @user,
        drive_item: @drive_item,
        since: STREAM_DEDUP_WINDOW.ago
      ).exists?
    end

    def actor_kind
      return "user" if @user.present?
      return "external_share" if @external_share.present?

      "anonymous"
    end

    def metadata
      {
        filename: @drive_item.filename,
        content_type: @drive_item.content_type,
        file_hash: @drive_item.file_hash,
        file_size: @drive_item.file_size
      }.merge(@metadata)
    end
  end
end
