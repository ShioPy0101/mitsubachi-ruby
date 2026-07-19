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

    write_storage_file(@file, "flower-pdf")
  end

  teardown do
    @storage_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "flower verify creates flower session and records audit without raw token" do
    raw_token = "flower-login-token"
    create_login_authentication(raw_token, user: @user)

    assert_difference "AuditEvent.where(action: 'flower.auth.login_verified').count", 1 do
      post api_v1_flower_verify_url, params: { token: raw_token }
    end

    assert_response :ok
    get api_v1_flower_me_url
    assert_response :ok
    assert_equal "flower", response.parsed_body.dig("data", "client_type")

    event = AuditEvent.where(action: "flower.auth.login_verified").last
    assert_equal "flower", event.metadata["client_type"]
    assert_not_includes event.metadata.to_json, raw_token
  end

  test "web verify does not create flower session" do
    raw_token = "web-login-token"
    create_login_authentication(raw_token, user: @user)

    post api_v1_auth_verify_url, params: { token: raw_token }
    assert_response :ok

    get api_v1_flower_me_url
    assert_response :unauthorized
  end

  test "flower login request uses common service and audits requested and failed events" do
    assert_difference "EmailAuthentication.count", 1 do
      assert_difference "AuditEvent.where(action: 'flower.auth.login_requested').count", 1 do
        post api_v1_flower_login_url, params: { email: " TEST1@example.com " }
      end
    end
    assert_response :ok

    assert_difference "AuditEvent.where(action: 'flower.auth.login_failed', outcome: 'failure').count", 1 do
      post api_v1_flower_login_url, params: { email: "missing@example.com" }
    end
    assert_response :unauthorized
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
  end

  test "flower me requires flower session and rejects suspended user" do
    get api_v1_flower_me_url
    assert_response :unauthorized

    flower_sign_in(@user)
    @user.update!(suspended_at: Time.current)
    get api_v1_flower_me_url
    assert_response :unauthorized
  end

  test "flower drive items index and show keep tenant boundary and directory file attrs null" do
    flower_sign_in(@user)

    assert_difference "AuditEvent.where(action: 'flower.drive_items.index').count", 1 do
      get api_v1_flower_drive_items_url, params: { parent_id: @file.parent_id, query: "report" }
    end
    assert_response :ok
    ids = response.parsed_body.fetch("items").map { |item| item.fetch("id") }
    assert_includes ids, @file.id.to_s
    assert_not_includes ids, @other_file.id.to_s
    assert_equal @file.reload.file_hash, response.parsed_body.fetch("items").first.fetch("file_hash")

    get api_v1_flower_drive_item_url(@folder)
    assert_response :ok
    item = response.parsed_body.fetch("item")
    assert_nil item.fetch("extension")
    assert_nil item.fetch("content_type")
    assert_nil item.fetch("file_size")
    assert_nil item.fetch("file_hash")

    get api_v1_flower_drive_item_url(@other_file)
    assert_response :not_found
  end

  test "flower resolve reports current updated deleted not_found invalid and enforces limit" do
    flower_sign_in(@user)

    assert_difference "AuditEvent.where(action: 'flower.drive_items.resolve').count", 1 do
      post resolve_api_v1_flower_drive_items_url, params: {
        items: [
          { id: @file.id, known_file_hash: @file.file_hash },
          { id: @file.id, known_file_hash: "sha256:old" },
          { id: @deleted_file.id, known_file_hash: @deleted_file.file_hash },
          { id: @other_file.id, known_file_hash: @other_file.file_hash },
          { id: "bad", known_file_hash: "x" }
        ]
      }
    end
    assert_response :ok
    statuses = response.parsed_body.fetch("items").map { |item| item.fetch("status") }
    assert_equal %w[current updated deleted not_found invalid], statuses

    post resolve_api_v1_flower_drive_items_url, params: {
      items: Array.new(DriveItems::Resolve::MAX_ITEMS + 1) { |index| { id: index + 1 } }
    }
    assert_response :unprocessable_entity
  end

  test "flower download uses x accel redirect and records access and audit metadata" do
    flower_sign_in(@user)

    assert_difference "DriveItemAccessLog.where(action: 'download').count", 1 do
      assert_difference "AuditEvent.where(action: 'flower.drive_item.download_started').count", 1 do
        get download_api_v1_flower_drive_item_url(@file), headers: request_headers
      end
    end

    assert_response :ok
    assert_equal "/internal/storage/drive_items/#{@file.storage_key}", response.headers["X-Accel-Redirect"]
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])

    access_log = DriveItemAccessLog.where(action: "download").last
    assert_equal "flower", access_log.metadata["client_type"]
    assert_equal @file.file_hash, access_log.metadata["file_hash"]
    assert_equal @file.file_size, access_log.metadata["file_size"]
    assert_not_includes response.body, @file.storage_key

    event = AuditEvent.where(action: "flower.drive_item.download_started").last
    assert_equal "flower", event.metadata["client_type"]
    assert_equal @file.file_hash, event.metadata["file_hash"]
  end

  test "flower download denial is audited without leaking tenant or storage path" do
    flower_sign_in(@user)

    assert_difference "AuditEvent.where(action: 'flower.drive_item.download_denied', outcome: 'denied').count", 1 do
      get download_api_v1_flower_drive_item_url(@other_file), headers: request_headers
    end

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
    assert_not_includes response.body, @other_file.storage_key

    assert_difference "AuditEvent.where(action: 'flower.drive_item.download_denied', outcome: 'denied').count", 1 do
      get download_api_v1_flower_drive_item_url(@folder), headers: request_headers
    end
    assert_response :unprocessable_entity
  end

  test "flower logout records audit and clears session" do
    flower_sign_in(@user)

    assert_difference "AuditEvent.where(action: 'flower.auth.logout').count", 1 do
      delete api_v1_flower_logout_url
    end
    assert_response :no_content

    get api_v1_flower_me_url
    assert_response :unauthorized
  end

  private

  def flower_sign_in(user)
    raw_token = "flower-token-#{SecureRandom.hex(6)}"
    create_login_authentication(raw_token, user: user)
    post api_v1_flower_verify_url, params: { token: raw_token }
    assert_response :ok
  end

  def create_login_authentication(raw_token, user:)
    EmailAuthentication.create!(
      email: user.email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      purpose: "login"
    )
  end

  def write_storage_file(drive_item, body)
    FileUtils.mkdir_p(DriveItem.storage_root.join("drive_items"))
    storage_key = "#{SecureRandom.uuid}.#{drive_item.extension}"
    drive_item.update_columns(
      storage_key: storage_key,
      blob_path: DriveItem.storage_relative_path_for(storage_key),
      file_hash: Digest::SHA256.hexdigest(body),
      file_size: body.bytesize,
      content_type: "application/pdf"
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
