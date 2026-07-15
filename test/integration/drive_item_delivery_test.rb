require "test_helper"
require "fileutils"

class DriveItemDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @drive_item = drive_items(:child_file)
    @other_item = drive_items(:two)

    sign_in @user

    FileUtils.mkdir_p(Rails.root.join("storage", "drive_items"))
    File.write(Rails.root.join("storage", @drive_item.storage_key), "%PDF-1.4 test file")
  end

  teardown do
    FileUtils.rm_f(Rails.root.join("storage", @drive_item.storage_key))
  end

  test "preview returns x accel redirect headers and writes access log" do
    assert_difference "DriveItemAccessLog.count", 1 do
      get preview_drive_item_url(@drive_item)
    end

    assert_response :ok
    assert_equal "/internal/storage/#{@drive_item.storage_key}", response.headers["X-Accel-Redirect"]
    assert_equal "application/pdf", response.headers["Content-Type"]
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])

    access_log = DriveItemAccessLog.order(:id).last
    assert_equal "preview", access_log.action
    assert_equal @user, access_log.user
    assert_equal @drive_item, access_log.drive_item
  end

  test "download returns attachment headers and writes access log" do
    assert_difference "DriveItemAccessLog.count", 1 do
      get download_drive_item_url(@drive_item)
    end

    assert_response :ok
    assert_equal "/internal/storage/#{@drive_item.storage_key}", response.headers["X-Accel-Redirect"]
    assert_equal "application/pdf", response.headers["Content-Type"]
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])

    access_log = DriveItemAccessLog.order(:id).last
    assert_equal "download", access_log.action
  end

  test "preview denies access to another organization item" do
    get preview_drive_item_url(@other_item)

    assert_response :not_found
  end

  test "preview rejects unsafe storage_key" do
    @drive_item.update_columns(storage_key: "../secret.txt", blob_path: "../secret.txt")

    get preview_drive_item_url(@drive_item)

    assert_response :not_found
  end
end
