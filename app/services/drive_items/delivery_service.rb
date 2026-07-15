module DriveItems
  class DeliveryService
    ACTION_CONFIG = {
      preview: { disposition: "inline" },
      stream: { disposition: "inline" },
      download: { disposition: "attachment" }
    }.freeze

    Result = Data.define(:success?, :status, :error_message, :headers) do
      def self.success(headers)
        new(true, :ok, nil, headers)
      end

      def self.failure(status, error_message)
        new(false, status, error_message, {})
      end
    end

    def initialize(drive_item:, current_user:, request:, action:)
      @drive_item = drive_item
      @current_user = current_user
      @request = request
      @action = action.to_sym
    end

    def call
      return Result.failure(:unprocessable_entity, "この操作はファイルに対してのみ可能です") unless @drive_item.file?

      storage_key = @drive_item.effective_storage_key
      return invalid_delivery("invalid_storage_key") unless DriveItem.valid_storage_key?(storage_key)

      absolute_path = @drive_item.absolute_storage_path
      return invalid_delivery("missing_file") unless File.exist?(absolute_path)

      audit_result = AuditLogs::Recorder.new(
        organization: @current_user.organization,
        user: @current_user,
        drive_item: @drive_item,
        action: @action,
        request: @request
      ).call
      return Result.failure(:service_unavailable, audit_result.error_message) unless audit_result.success?

      Result.success(
        "X-Accel-Redirect" => x_accel_redirect(storage_key),
        "Content-Type" => content_type(absolute_path),
        "Content-Disposition" => content_disposition
      )
    rescue StandardError => error
      Rails.logger.error(
        "[drive_items.delivery_service] failed drive_item_id=#{@drive_item.id} action=#{@action} " \
        "request_id=#{@request.request_id} error=#{error.class}: #{error.message}"
      )
      Result.failure(:service_unavailable, "配信を準備できませんでした")
    end

    private

    def invalid_delivery(reason)
      Rails.logger.warn(
        "[drive_items.delivery_service] denied reason=#{reason} drive_item_id=#{@drive_item.id} " \
        "organization_id=#{@current_user.organization.id} user_id=#{@current_user.id} request_id=#{@request.request_id}"
      )
      Result.failure(:not_found, "指定されたファイルが見つかりません")
    end

    def x_accel_redirect(storage_key)
      "/internal/storage/#{DriveItem.storage_relative_path_for(storage_key)}"
    end

    def content_type(absolute_path)
      @drive_item.content_type.presence ||
        Marcel::MimeType.for(Pathname.new(absolute_path), name: @drive_item.filename) ||
        "application/octet-stream"
    end

    def content_disposition
      ActionDispatch::Http::ContentDisposition.format(
        disposition: ACTION_CONFIG.fetch(@action).fetch(:disposition),
        filename: sanitized_filename
      )
    end

    def sanitized_filename
      @drive_item.filename.to_s.delete("\r\n")
    end
  end
end
