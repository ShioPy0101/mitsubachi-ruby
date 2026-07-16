require "test_helper"
require "fileutils"
require "digest"

class AdminDriveItemFileAccessTest < ActionDispatch::IntegrationTest
  setup do
    @organization = organizations(:one)
    @other_organization = organizations(:two)
    @member = users(:one)
    @system_admin = create_user(role: :system_admin, organization: @organization, email: "admin-file-system@example.com")
    @organization_admin = create_user(role: :organization_admin, organization: @organization, email: "admin-file-org@example.com")
    @other_file = drive_items(:two)
    @own_file = drive_items(:child_file)
    @directory = drive_items(:one)
    @deleted_file = drive_items(:deleted_report)
    @storage_paths = []

    prepare_file(@other_file, "other organization payload")
    prepare_file(@own_file, "own organization payload")
    prepare_file(@deleted_file, "deleted payload")
  end

  teardown do
    @storage_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "system_admin can preview a file from another organization" do
    sign_in @system_admin

    assert_difference "AdminAuditLog.where(action: 'drive_item.preview').count", 1 do
      get preview_api_v1_admin_drive_item_url(@other_file), headers: request_headers
    end

    assert_response :ok
    assert_equal "/internal/storage/drive_items/#{@other_file.storage_key}", response.headers["X-Accel-Redirect"]
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
    assert_equal @other_organization, DriveItemAccessLog.order(:id).last.organization
  end

  test "system_admin can download a file from another organization" do
    sign_in @system_admin

    assert_difference "AdminAuditLog.where(action: 'drive_item.download').count", 1 do
      get download_api_v1_admin_drive_item_url(@other_file), headers: request_headers
    end

    assert_response :ok
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
  end

  test "system_admin can stream a file from another organization" do
    sign_in @system_admin

    assert_difference "AdminAuditLog.where(action: 'drive_item.stream').count", 1 do
      get stream_api_v1_admin_drive_item_url(@other_file), headers: request_headers.merge("Range" => "bytes=0-10")
    end

    assert_response :ok
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
  end

  test "organization_admin cannot access another organization file" do
    sign_in @organization_admin

    get preview_api_v1_admin_drive_item_url(@other_file), headers: request_headers

    assert_response :not_found
  end

  test "member cannot access admin delivery" do
    sign_in @member

    get preview_api_v1_admin_drive_item_url(@own_file), headers: request_headers

    assert_response :forbidden
  end

  test "unauthenticated admin delivery returns unauthorized" do
    get preview_api_v1_admin_drive_item_url(@own_file), headers: request_headers

    assert_response :unauthorized
  end

  test "directory delivery is rejected" do
    sign_in @system_admin

    get preview_api_v1_admin_drive_item_url(@directory), headers: request_headers

    assert_response :unprocessable_entity
  end

  test "deleted file delivery is rejected" do
    sign_in @system_admin

    get preview_api_v1_admin_drive_item_url(@deleted_file), headers: request_headers

    assert_response :not_found
  end

  test "admin drive item detail includes upload metadata" do
    @own_file.update!(upload_ip_address: "198.51.100.20")
    sign_in @system_admin

    get api_v1_admin_drive_item_url(@own_file)

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal @own_file.owner_user_id, data.fetch("owner_user_id")
    assert_equal @own_file.owner_user.email, data.fetch("owner_email")
    assert_equal "198.51.100.20", data.fetch("upload_ip_address")
    assert_equal @own_file.created_at.iso8601(3), data.fetch("uploaded_at")
    assert_equal @own_file.file_size, data.fetch("file_size")
    assert_equal @own_file.created_at.iso8601(3), data.fetch("created_at")
    assert_equal @own_file.updated_at.iso8601(3), data.fetch("updated_at")
    assert_nil data.fetch("deleted_at")
  end

  test "system_admin can purge an already soft-deleted file" do
    sign_in @system_admin
    storage_path = @deleted_file.absolute_storage_path
    access_log = DriveItemAccessLog.create!(
      organization: @deleted_file.organization,
      user: @deleted_file.owner_user,
      drive_item: @deleted_file,
      action: "download",
      occurred_at: Time.current,
      ip_address: "203.0.113.70",
      request_id: "purge-retain-log"
    )

    assert File.exist?(storage_path)
    assert_difference "AdminAuditLog.where(action: 'drive_item.purge').count", 1 do
      assert_no_difference "DriveItemAccessLog.count" do
        delete purge_api_v1_admin_drive_item_url(@deleted_file)
      end
    end

    assert_response :ok
    assert_equal({ "message" => "ファイルを完全削除しました" }, response.parsed_body)
    assert_not DriveItem.exists?(@deleted_file.id)
    assert_not File.exist?(storage_path)
    assert_nil access_log.reload.drive_item_id
  end

  test "system_admin cannot purge an active file first" do
    sign_in @system_admin

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_admin_drive_item_url(@own_file)
    end

    assert_response :unprocessable_entity
    assert_equal({ "error" => "先にゴミ箱へ移動してください" }, response.parsed_body)
  end

  test "organization_admin cannot purge" do
    sign_in @organization_admin

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_admin_drive_item_url(@deleted_file)
    end

    assert_response :forbidden
  end

  test "member cannot purge" do
    sign_in @member

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_admin_drive_item_url(@deleted_file)
    end

    assert_response :forbidden
  end

  test "purge rejects invalid storage_key without deleting arbitrary paths" do
    sign_in @system_admin
    safe_path = @deleted_file.absolute_storage_path
    @deleted_file.update_columns(storage_key: "../secret.txt", blob_path: "drive_items/../secret.txt")

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_admin_drive_item_url(@deleted_file)
    end

    assert_response :unprocessable_entity
    assert File.exist?(safe_path)
  end

  test "purge rejects symlink storage targets" do
    sign_in @system_admin
    symlink_key = "#{SecureRandom.uuid}.txt"
    symlink_path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(symlink_key))
    FileUtils.mkdir_p(symlink_path.dirname)
    FileUtils.ln_s(@deleted_file.absolute_storage_path, symlink_path)
    @storage_paths << symlink_path
    @deleted_file.update_columns(
      storage_key: symlink_key,
      blob_path: DriveItem.storage_relative_path_for(symlink_key)
    )

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_admin_drive_item_url(@deleted_file)
    end

    assert_response :not_found
    assert File.symlink?(symlink_path)
  end

  private

  def create_user(role:, organization:, email:)
    User.create!(
      organization: organization,
      email: email,
      name: email.split("@").first,
      password: "password123",
      role: role
    )
  end

  def prepare_file(drive_item, body)
    storage_key = "#{SecureRandom.uuid}.#{drive_item.extension.presence || 'txt'}"
    drive_item.update_columns(
      storage_key: storage_key,
      blob_path: DriveItem.storage_relative_path_for(storage_key),
      file_hash: Digest::SHA256.hexdigest(body),
      file_size: body.bytesize,
      content_type: drive_item.content_type.presence || "text/plain"
    )
    path = drive_item.absolute_storage_path
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body)
    @storage_paths << path
  end

  def request_headers
    {
      "REMOTE_ADDR" => "203.0.113.50",
      "HTTP_USER_AGENT" => "AdminFileAccessTest/1.0"
    }
  end
end
