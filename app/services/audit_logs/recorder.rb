module AuditLogs
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

    def initialize(organization:, user:, drive_item:, action:, request:)
      @organization = organization
      @user = user
      @drive_item = drive_item
      @action = action.to_s
      @request = request
    end

    def call
      return Result.success if skip_stream_log?

      DriveItemAccessLog.create!(
        organization: @organization,
        user: @user,
        drive_item: @drive_item,
        action: @action,
        occurred_at: Time.current,
        ip_address: @request.remote_ip,
        user_agent: @request.user_agent.to_s,
        request_id: @request.request_id.to_s,
        metadata: metadata
      )

      Result.success
    rescue StandardError => error
      Rails.logger.error(
        "[audit_logs.recorder] failed organization_id=#{@organization.id} user_id=#{@user.id} " \
        "drive_item_id=#{@drive_item.id} action=#{@action} request_id=#{@request.request_id} " \
        "error=#{error.class}: #{error.message}"
      )
      Result.failure("監査ログの保存に失敗しました")
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

    def metadata
      {
        filename: @drive_item.filename,
        content_type: @drive_item.content_type,
        storage_key: @drive_item.storage_key
      }
    end
  end
end
