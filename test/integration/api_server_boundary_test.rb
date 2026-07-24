require "test_helper"
require "tempfile"

class ApiServerBoundaryTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @root = drive_items(:one)
    @other_root = drive_items(:two)
    @tempfiles = []
  end

  teardown do
    @tempfiles.each do |tempfile|
      tempfile.close
      tempfile.unlink
    end
  end

  test "drive item API is exposed under api v1" do
    sign_in @user

    get api_v1_drive_items_url

    assert_response :ok
  end

  test "legacy root drive item path is not routed" do
    get "/drive_items"

    assert_response :not_found
  end

  test "csrf token endpoint returns a token for same origin frontend" do
    get api_v1_csrf_token_url

    assert_response :ok
    assert response.parsed_body["csrf_token"].present?
  end

  test "me endpoint returns the authenticated user" do
    sign_in @user

    get api_v1_me_url

    assert_response :ok
    assert_equal(
      {
        "id" => @user.id,
        "organization_id" => @user.organization_id,
        "organization_name" => @user.organization.name,
        "email" => @user.email,
        "pending_email" => nil,
        "name" => @user.name,
        "display_name" => @user.display_name,
        "role" => @user.role,
        "suspended" => false,
        "suspended_at" => nil,
        "last_sign_in_at" => @user.last_sign_in_at&.iso8601(3),
        "created_at" => @user.created_at.iso8601(3),
        "updated_at" => @user.updated_at.iso8601(3)
      },
      response.parsed_body.fetch("data")
    )
  end

  test "me endpoint requires authentication" do
    get api_v1_me_url

    assert_response :unauthorized
  end

  test "cors headers are added to api not found responses for allowed frontend origin" do
    get "/api/v1/missing", headers: { "Origin" => "http://localhost:5173" }

    assert_response :not_found
    assert_equal "http://localhost:5173", response.headers["Access-Control-Allow-Origin"]
    assert_equal "true", response.headers["Access-Control-Allow-Credentials"]
    assert_equal "Origin", response.headers["Vary"]
  end

  test "security headers are added to api responses" do
    get api_health_url

    assert_response :ok
    assert_equal "DENY", response.headers["X-Frame-Options"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_equal "camera=(), microphone=(), geolocation=()", response.headers["Permissions-Policy"]
  end

  test "cors preflight succeeds for allowed frontend origin" do
    process(
      :options,
      api_v1_me_url,
      headers: {
        "Origin" => "http://localhost:5173",
        "Access-Control-Request-Method" => "GET"
      }
    )

    assert_response :no_content
    assert_equal "http://localhost:5173", response.headers["Access-Control-Allow-Origin"]
  end

  test "me endpoint rejects suspended user sessions" do
    sign_in @user
    @user.update!(suspended_at: Time.current)

    get api_v1_me_url

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    assert_equal "このユーザーは停止されています", response.parsed_body.dig("error", "message")
    assert response.parsed_body.dig("error", "request_id").present?
  end

  test "state changing requests require csrf when forgery protection is enabled" do
    original = Rails.configuration.action_controller.allow_forgery_protection
    Rails.configuration.action_controller.allow_forgery_protection = true
    sign_in @user

    post api_v1_drive_items_url, params: { name: "csrf-check", item_type: "directory" }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal "認証情報の確認に失敗しました。再読み込みしてからやり直してください", response.parsed_body.dig("error", "message")
    assert response.parsed_body.dig("error", "request_id").present?
  ensure
    Rails.configuration.action_controller.allow_forgery_protection = original
  end

  test "logout clears authenticated session" do
    sign_in @user

    delete api_v1_logout_url

    assert_response :no_content

    get api_v1_drive_items_url

    assert_response :unauthorized
  end

  test "suspended user cannot continue using an existing session" do
    sign_in @user
    @user.update!(suspended_at: Time.current)

    get api_v1_drive_items_url

    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
    assert_equal "このユーザーは停止されています", response.parsed_body.dig("error", "message")
    assert response.parsed_body.dig("error", "request_id").present?
  end

  test "suspended user can still call logout" do
    sign_in @user
    @user.update!(suspended_at: Time.current)

    delete api_v1_logout_url

    assert_response :no_content
  end

  test "other organization parent cannot be used on create" do
    sign_in @user

    post api_v1_drive_items_url, params: {
      name: "cross-tenant",
      item_type: "directory",
      parent_id: @other_root.id
    }

    assert_response :not_found
  end

  test "upload size limit returns 413" do
    original = Rails.configuration.x.max_upload_size_bytes
    Rails.configuration.x.max_upload_size_bytes = 1
    sign_in @user

    post api_v1_drive_items_url, params: {
      name: "too-large",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("too-large.txt", "xx")
    }

    assert_response :content_too_large
  ensure
    Rails.configuration.x.max_upload_size_bytes = original
  end

  test "health endpoints do not expose internal details" do
    get api_health_url

    assert_response :ok
    assert_equal({ "status" => "ok" }, response.parsed_body)

    get api_health_live_url

    assert_response :ok
    assert_equal({ "status" => "ok" }, response.parsed_body)

    get api_health_ready_url

    assert_response :ok
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  private

  def uploaded_file(filename, content)
    tempfile = Tempfile.new([ File.basename(filename, ".*"), File.extname(filename) ])
    tempfile.binmode
    tempfile.write(content)
    tempfile.rewind
    @tempfiles << tempfile
    Rack::Test::UploadedFile.new(tempfile.path, "text/plain", original_filename: filename)
  end
end
