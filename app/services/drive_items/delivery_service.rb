module DriveItems
  # DriveItem の実ファイル配信に必要な認可後処理をまとめる。
  #
  # Controller は入口ごとの authentication / authorization だけを担当し、この Service は
  # 監査ログの記録、保存先の安全性確認、Nginx へ委譲するレスポンスヘッダー生成を担う。
  # 実ファイルの転送は Rails で行わず、Puma worker を占有しないよう X-Accel-Redirect に委譲する。
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

    def initialize(drive_item:, current_user:, request:, action:, audit_organization: nil, external_share: nil, client_type: "web", record_audit: true)
      @drive_item = drive_item
      @current_user = current_user
      @request = request
      @action = action.to_sym
      @audit_organization = audit_organization || drive_item.organization
      @external_share = external_share
      @client_type = client_type
      @record_audit = record_audit
    end

    # 認可済み DriveItem を配信可能なレスポンスヘッダーへ変換する。
    #
    # @return [Result] 成功時は Nginx 内部 URI と安全な配信ヘッダー、失敗時は API 用 status/message を返す。
    # @raise [StandardError] 想定外の storage / audit / MIME 判定エラーは捕捉して SystemEvent に記録する。
    def call
      return Result.failure(:unprocessable_content, "この操作はファイルに対してのみ可能です") unless @drive_item.file?

      storage_key = @drive_item.effective_storage_key
      return invalid_delivery("invalid_storage_key") unless DriveItem.valid_storage_key?(storage_key)

      absolute_path = @drive_item.absolute_storage_path
      return invalid_delivery("missing_file") unless File.exist?(absolute_path)

      ensure_proxy_readable!(absolute_path)

      audit_result = record_access_log
      return Result.failure(:service_unavailable, audit_result.error_message) unless audit_result.success?

      Result.success(delivery_headers(storage_key:, absolute_path:))
    rescue StandardError => error
      SystemEvents::Recorder.record!(
        event_type: "storage.delivery_preparation_failed",
        severity: "error",
        source: "storage",
        organization: @audit_organization,
        related_user: @current_user,
        target: @drive_item,
        request: @request,
        error: error,
        metadata: { action: @action }
      )
      Rails.logger.error(
        "[drive_items.delivery_service] failed drive_item_id=#{@drive_item.id} action=#{@action} " \
        "request_id=#{@request.request_id} error=#{error.class}: #{error.message}"
      )
      Result.failure(:service_unavailable, "配信を準備できませんでした")
    end

    private

    def record_access_log
      return DriveItemAccessLogs::Recorder::Result.success unless @record_audit

      # authorization 成功後かつ Nginx へ配信を許可する直前に記録することで、
      # 拒否されたアクセスを成功ログとして残さず、実配信された操作だけを追跡する。
      DriveItemAccessLogs::Recorder.new(
        organization: @audit_organization,
        user: @current_user,
        external_share: @external_share,
        drive_item: @drive_item,
        action: @action,
        request: @request,
        metadata: { client_type: @client_type }
      ).call
    end

    def delivery_headers(storage_key:, absolute_path:)
      {
        "X-Accel-Redirect" => x_accel_redirect(storage_key),
        "Content-Type" => content_type(absolute_path),
        "Content-Disposition" => content_disposition,
        "ETag" => etag,
        "Accept-Ranges" => "bytes",
        "X-Mitsubachi-Drive-Item-Id" => @drive_item.id.to_s,
        "X-Mitsubachi-File-Sha256" => normalized_sha256.to_s,
        "X-Mitsubachi-Updated-At" => @drive_item.updated_at.iso8601(3)
      }
    end

    def ensure_proxy_readable!(absolute_path)
      return if (File.stat(absolute_path).mode & DriveItems::StoredFileInspector::PUBLISHED_FILE_MODE) == DriveItems::StoredFileInspector::PUBLISHED_FILE_MODE

      # atomic publish 導入直後に作成されたファイルは staging 時の 0600 を引き継ぐ可能性がある。
      # Rails が本文を直配信するのではなく、X-Accel-Redirect 先の Nginx が読める mode へ
      # 認可済みリクエストの直前に補正して、既存ファイルも同じ配信境界で自己修復する。
      File.chmod(DriveItems::StoredFileInspector::PUBLISHED_FILE_MODE, absolute_path)
    end

    def invalid_delivery(reason)
      SystemEvents::Recorder.record!(
        event_type: reason == "missing_file" ? "storage.file_missing" : "storage.invalid_key_detected",
        severity: reason == "missing_file" ? "error" : "warning",
        source: "storage",
        organization: @audit_organization,
        related_user: @current_user,
        target: @drive_item,
        request: @request,
        metadata: { action: @action }
      )
      Rails.logger.warn(
        "[drive_items.delivery_service] denied reason=#{reason} drive_item_id=#{@drive_item.id} " \
        "organization_id=#{@audit_organization.id} user_id=#{@current_user&.id} request_id=#{@request.request_id}"
      )
      Result.failure(:not_found, "指定されたファイルが見つかりません")
    end

    def x_accel_redirect(storage_key)
      # storage_key は valid_storage_key? でファイル名相当の値に限定済み。
      # ユーザー入力をそのまま内部 URI へ連結すると path traversal が X-Accel-Redirect へ届くため、
      # DriveItem の保存規約に沿った相対パス生成だけを入口にする。
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

    def etag
      value = normalized_sha256.presence || @drive_item.cache_key_with_version
      %("#{value}")
    end

    def normalized_sha256
      value = @drive_item.file_hash.to_s.downcase.delete_prefix("sha256:")
      return unless value.match?(/\A[0-9a-f]{64}\z/)

      "sha256:#{value}"
    end
  end
end
