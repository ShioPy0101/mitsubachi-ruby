module MediaPreviews
  # 認可済み DriveItem の thumbnail cache を生成し、Nginx 配信用headersへ変換する。
  class DeliveryService
    Result = Data.define(:success?, :status, :error_message, :headers)

    attr_reader :etag

    def initialize(drive_item:, current_user:, request:, external_share: nil, generator: nil)
      @drive_item = drive_item
      @current_user = current_user
      @request = request
      @external_share = external_share
      @cache_path = CachePath.new(drive_item:)
      @generator = generator || Generator.new(drive_item:)
      @etag = @cache_path.etag
    end

    def call
      return failure(:not_found, "指定されたファイルが見つかりません") unless valid_original?

      generated = @generator.call
      return failure(generated.status, generated.error_message) unless generated.success?

      audit = DriveItemAccessLogs::Recorder.new(
        organization: @drive_item.organization,
        user: @current_user,
        external_share: @external_share,
        drive_item: @drive_item,
        action: :preview,
        request: @request,
        metadata: { client_type: @external_share ? "external_share_thumbnail" : "web_thumbnail" }
      ).call
      return failure(:service_unavailable, audit.error_message) unless audit.success?

      Result.new(true, :ok, nil, {
        "X-Accel-Redirect" => @cache_path.internal_uri,
        "Content-Type" => "image/jpeg",
        "Content-Disposition" => "inline",
        "ETag" => %Q("#{etag}"),
        "Cache-Control" => "private, max-age=86400",
        "X-Content-Type-Options" => "nosniff"
      })
    end

    private

    def valid_original?
      key = @drive_item.effective_storage_key
      @drive_item.file? && DriveItem.valid_storage_key?(key) && File.file?(@drive_item.absolute_storage_path)
    end

    def failure(status, message)
      Result.new(false, status, message, {})
    end
  end
end
