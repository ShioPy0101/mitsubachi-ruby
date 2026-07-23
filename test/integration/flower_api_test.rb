require "test_helper"
require "digest"
require "fileutils"

class FlowerApiTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @user = users(:one)
    @file = drive_items(:child_file)
    @folder = drive_items(:child_folder)
    @other_file = drive_items(:two)
    @deleted_file = drive_items(:deleted_report)
    @storage_paths = []

    write_storage_file(@file, "flower-video", content_type: "video/mp4", extension: "mp4")
  end

  teardown do
    @storage_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "device authorization stores digests and does not persist plaintext codes" do
    assert_difference "FlowerDeviceAuthorization.count", 1 do
      assert_difference "AuditEvent.where(action: 'flower.device_authorization.created').count", 1 do
        post api_v1_flower_device_authorizations_url, params: device_params
      end
    end

    assert_response :ok
    body = response.parsed_body
    assert_match(/\A[A-Za-z0-9_-]{64,}\z/, body.fetch("device_code"))
    assert_match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/, body.fetch("user_code"))
    assert_equal 5, body.fetch("interval")
    assert_equal "http://localhost:5173/flower/activate", body.fetch("verification_uri")
    assert_equal "http://localhost:5173/flower/activate?user_code=#{body.fetch("user_code")}", body.fetch("verification_uri_complete")

    authorization = FlowerDeviceAuthorization.last
    assert_equal Flower::DeviceAuthorizations::Code.device_code_digest(body.fetch("device_code")), authorization.device_code_digest
    assert_equal Flower::DeviceAuthorizations::Code.user_code_digest(body.fetch("user_code")), authorization.user_code_digest
    assert_not_equal body.fetch("device_code"), authorization.device_code_digest
    assert_not_includes authorization.attributes.values.join(" "), body.fetch("user_code")
  end

  test "browser user approves device authorization and token polling issues bearer token once" do
    post api_v1_flower_device_authorizations_url, params: device_params
    device_code = response.parsed_body.fetch("device_code")
    user_code = response.parsed_body.fetch("user_code")

    post api_v1_flower_tokens_url, params: token_params(device_code)
    assert_response :bad_request
    assert_equal "authorization_pending", response.parsed_body.dig("error", "code")

    sign_in @user
    assert_difference "AuditEvent.where(action: 'flower.authorization.approved').count", 1 do
      post approve_api_v1_flower_device_authorizations_url, params: {
        user_code: user_code.downcase.delete("-"),
        organization_id: @user.organization_id
      }
    end
    assert_response :ok
    Rails.cache.clear

    travel 6.seconds do
      assert_difference "FlowerAccessToken.count", 1 do
        assert_difference "AuditEvent.where(action: 'flower.token.issued').count", 1 do
          post api_v1_flower_tokens_url, params: token_params(device_code)
        end
      end
    end

    assert_response :ok
    body = response.parsed_body
    assert_equal "Bearer", body.fetch("token_type")
    assert_equal "flower:read flower:download", body.fetch("scope")
    assert_nil body["refresh_token"]

    token = FlowerAccessToken.last
    assert_equal Flower::Tokens::Codec.digest(body.fetch("access_token")), token.access_token_digest
    assert_not_equal body.fetch("access_token"), token.access_token_digest
    assert_equal "consumed", token.flower_device_authorization.status

    travel 6.seconds do
      post api_v1_flower_tokens_url, params: token_params(device_code)
    end
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body.dig("error", "code")
  end

  test "token polling returns slow_down when polling too frequently" do
    post api_v1_flower_device_authorizations_url, params: device_params
    device_code = response.parsed_body.fetch("device_code")

    post api_v1_flower_tokens_url, params: token_params(device_code)
    assert_response :bad_request
    assert_equal "authorization_pending", response.parsed_body.dig("error", "code")

    post api_v1_flower_tokens_url, params: token_params(device_code)
    assert_response :too_many_requests
    assert_equal "slow_down", response.parsed_body.dig("error", "code")
  end

  test "denied and expired device authorizations cannot issue tokens" do
    post api_v1_flower_device_authorizations_url, params: device_params
    device_code = response.parsed_body.fetch("device_code")
    user_code = response.parsed_body.fetch("user_code")

    sign_in @user
    post deny_api_v1_flower_device_authorizations_url, params: { user_code: user_code }
    assert_response :ok

    travel 6.seconds do
      post api_v1_flower_tokens_url, params: token_params(device_code)
    end
    assert_response :bad_request
    assert_equal "access_denied", response.parsed_body.dig("error", "code")

    expired = FlowerDeviceAuthorization.create!(
      device_code_digest: Flower::DeviceAuthorizations::Code.device_code_digest("expired-device"),
      user_code_digest: Flower::DeviceAuthorizations::Code.user_code_digest("ZZZZ-9999"),
      expires_at: 1.minute.ago
    )
    post api_v1_flower_tokens_url, params: token_params("expired-device")
    assert_response :bad_request
    assert_equal "expired_token", response.parsed_body.dig("error", "code")
    assert_equal "expired", expired.reload.status
  end

  test "flower protected endpoints require bearer token and never fallback to cookie or query token" do
    sign_in @user

    get api_v1_flower_me_url
    assert_response :unauthorized

    token = create_access_token(scopes: FlowerAccessToken::DEFAULT_SCOPES)
    get api_v1_flower_me_url, params: { access_token: token }
    assert_response :unauthorized
  end

  test "flower me returns minimal user and organization data" do
    token = create_access_token(scopes: FlowerAccessToken::DEFAULT_SCOPES)

    get api_v1_flower_me_url, headers: bearer_headers(token)

    assert_response :ok
    assert_equal @user.id.to_s, response.parsed_body.dig("user", "id")
    assert_equal @user.safe_display_name, response.parsed_body.dig("user", "name")
    assert_nil response.parsed_body.dig("user", "email")
    assert_equal @user.organization_id.to_s, response.parsed_body.dig("organization", "id")
    assert_equal %w[flower:read flower:download], response.parsed_body.fetch("scopes")
  end

  test "flower drive items list filters media files and hides storage internals" do
    token = create_access_token(scopes: [ "flower:read" ])
    image = create_media_file(name: "still", extension: "png", content_type: "image/png", body: "image")
    create_media_file(name: "text", extension: "txt", content_type: "text/plain", body: "text")

    assert_difference "AuditEvent.where(action: 'flower.drive_item.listed').count", 1 do
      get api_v1_flower_drive_items_url, params: { limit: 1 }, headers: bearer_headers(token)
    end

    assert_response :ok
    body = response.parsed_body
    assert_equal 1, body.fetch("items").size
    assert body.dig("pagination", "next_cursor").present?

    get api_v1_flower_drive_items_url, params: { query: "still" }, headers: bearer_headers(token)
    assert_response :ok
    ids = response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    assert_includes ids, image.id.to_s
    refute_includes ids, @folder.id.to_s
    refute_includes ids, @deleted_file.id.to_s
    refute_includes ids, @other_file.id.to_s

    item = response.parsed_body.fetch("items").first
    assert_match(/\Asha256:[0-9a-f]{64}\z/, item.fetch("sha256"))
    assert_not_includes item.keys, "storage_key"
    assert_not_includes item.keys, "blob_path"
  end

  test "flower drive item show respects organization boundary and scope" do
    token = create_access_token(scopes: [ "flower:read" ])

    get api_v1_flower_drive_item_url(@file), headers: bearer_headers(token)
    assert_response :ok
    assert_equal @file.id.to_s, response.parsed_body.fetch("id")
    assert_equal true, response.parsed_body.dig("download", "available")

    get api_v1_flower_drive_item_url(@other_file), headers: bearer_headers(token)
    assert_response :not_found

    download_only = create_access_token(scopes: [ "flower:download" ])
    get api_v1_flower_drive_item_url(@file), headers: bearer_headers(download_only)
    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
  end

  test "flower download uses x accel redirect and safe headers" do
    token = create_access_token(scopes: FlowerAccessToken::DEFAULT_SCOPES)

    assert_difference "DriveItemAccessLog.where(action: 'download').count", 1 do
      assert_difference "AuditEvent.where(action: 'flower.file.downloaded').count", 1 do
        get download_api_v1_flower_drive_item_url(@file), headers: bearer_headers(token).merge(request_headers)
      end
    end

    assert_response :ok
    assert_equal "/internal/storage/drive_items/#{@file.storage_key}", response.headers["X-Accel-Redirect"]
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_equal @file.id.to_s, response.headers["X-Mitsubachi-Drive-Item-Id"]
    assert_match(/\Asha256:[0-9a-f]{64}\z/, response.headers["X-Mitsubachi-File-Sha256"])
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_not_includes response.body, @file.storage_key

    access_log = DriveItemAccessLog.where(action: "download").last
    assert_equal "flower", access_log.metadata["client_type"]
    assert_nil access_log.metadata["storage_key"]
  end

  test "flower download rejects boundary deleted directory suspended and missing scope" do
    token = create_access_token(scopes: FlowerAccessToken::DEFAULT_SCOPES)

    assert_difference "AuditEvent.where(action: 'flower.download.denied', outcome: 'denied').count", 1 do
      get download_api_v1_flower_drive_item_url(@other_file), headers: bearer_headers(token)
    end
    assert_response :not_found

    get download_api_v1_flower_drive_item_url(@deleted_file), headers: bearer_headers(token)
    assert_response :not_found

    get download_api_v1_flower_drive_item_url(@folder), headers: bearer_headers(token)
    assert_response :unprocessable_entity

    read_only = create_access_token(scopes: [ "flower:read" ])
    get download_api_v1_flower_drive_item_url(@file), headers: bearer_headers(read_only)
    assert_response :forbidden

    @user.update!(suspended_at: Time.current)
    get download_api_v1_flower_drive_item_url(@file), headers: bearer_headers(token)
    assert_response :unauthorized
  end

  private

  def device_params
    {
      client_name: "mitsubachi-flower",
      client_version: "0.1.0",
      device_name: "After Effects 2022 on Windows"
    }
  end

  def token_params(device_code)
    {
      grant_type: Flower::Tokens::Exchange::GRANT_TYPE,
      device_code: device_code
    }
  end

  def create_access_token(scopes:)
    raw_token = "flower-access-#{SecureRandom.hex(24)}"
    FlowerAccessToken.create!(
      user: @user,
      organization: @user.organization,
      access_token_digest: Flower::Tokens::Codec.digest(raw_token),
      scopes: scopes,
      expires_at: 15.minutes.from_now
    )
    raw_token
  end

  def bearer_headers(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def create_media_file(name:, extension:, content_type:, body:)
    storage_key = "#{SecureRandom.uuid}.#{extension}"
    FileUtils.mkdir_p(DriveItem.storage_root.join("drive_items"))
    path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))
    File.binwrite(path, body)
    @storage_paths << path

    DriveItem.create!(
      organization: @user.organization,
      owner_user: @user,
      name: name,
      item_type: "file",
      extension: extension,
      storage_key: storage_key,
      blob_path: DriveItem.storage_relative_path_for(storage_key),
      content_type: content_type,
      file_size: body.bytesize,
      file_hash: Digest::SHA256.hexdigest(body)
    )
  end

  def write_storage_file(drive_item, body, content_type:, extension:)
    FileUtils.mkdir_p(DriveItem.storage_root.join("drive_items"))
    storage_key = "#{SecureRandom.uuid}.#{extension}"
    drive_item.update_columns(
      extension: extension,
      storage_key: storage_key,
      blob_path: DriveItem.storage_relative_path_for(storage_key),
      file_hash: Digest::SHA256.hexdigest(body),
      file_size: body.bytesize,
      content_type: content_type
    )
    File.binwrite(drive_item.absolute_storage_path, body)
    @storage_paths << drive_item.absolute_storage_path
  end

  def request_headers
    {
      "REMOTE_ADDR" => "203.0.113.30",
      "HTTP_USER_AGENT" => "FlowerTest/1.0"
    }
  end
end
