require "test_helper"
require "fileutils"
require "digest"

class DriveItemDeliveryTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:one)
    @drive_item = drive_items(:child_file)
    @other_item = drive_items(:two)

    FileUtils.mkdir_p(Rails.root.join("storage", "drive_items"))
    File.binwrite(@drive_item.absolute_storage_path, pdf_payload)
    @drive_item.update_columns(
      file_hash: Digest::SHA256.hexdigest(pdf_payload),
      file_size: pdf_payload.bytesize,
      content_type: "application/pdf"
    )
  end

  teardown do
    travel_back
    FileUtils.rm_f(@drive_item.absolute_storage_path)
  end

  test "未認証では配信できない" do
    get preview_drive_item_url(@drive_item)

    assert_response :unauthorized
  end

  test "preview は同じ organization のファイルを inline 配信する" do
    sign_in @user

    assert_difference "DriveItemAccessLog.count", 1 do
      get preview_drive_item_url(@drive_item), headers: request_headers
    end

    assert_response :ok
    assert_equal "/internal/storage/drive_items/#{@drive_item.storage_key}", response.headers["X-Accel-Redirect"]
    assert_equal "application/pdf", response.headers["Content-Type"]
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])

    log = DriveItemAccessLog.order(:id).last
    assert_equal "preview", log.action
    assert_equal "203.0.113.10", log.ip_address
    assert_equal "DeliveryTest/1.0", log.user_agent
    assert_equal @user.organization, log.organization
  end

  test "download は attachment を返す" do
    sign_in @user

    assert_difference "DriveItemAccessLog.count", 1 do
      get download_drive_item_url(@drive_item), headers: request_headers
    end

    assert_response :ok
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_equal "download", DriveItemAccessLog.order(:id).last.action
  end

  test "stream は inline を返す" do
    sign_in @user

    assert_difference "DriveItemAccessLog.count", 1 do
      get stream_drive_item_url(@drive_item), headers: request_headers.merge("Range" => "bytes=0-10")
    end

    assert_response :ok
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
    assert_equal "stream", DriveItemAccessLog.order(:id).last.action
  end

  test "他 organization のファイルは配信できない" do
    sign_in @user

    get preview_drive_item_url(@other_item), headers: request_headers

    assert_response :not_found
  end

  test "削除済みファイルは配信できない" do
    sign_in @user
    @drive_item.update!(deleted_at: Time.current)

    get preview_drive_item_url(@drive_item), headers: request_headers

    assert_response :not_found
  end

  test "危険な storage_key は拒否する" do
    sign_in @user
    @drive_item.update_columns(storage_key: "../secret.pdf", blob_path: "drive_items/../secret.pdf")

    get preview_drive_item_url(@drive_item), headers: request_headers

    assert_response :not_found
  end

  test "実ファイルが存在しない場合は配信できない" do
    sign_in @user
    FileUtils.rm_f(@drive_item.absolute_storage_path)

    get preview_drive_item_url(@drive_item), headers: request_headers

    assert_response :not_found
  end

  test "日本語ファイル名でも Content-Disposition を生成する" do
    sign_in @user
    @drive_item.update!(name: "日本語資料")

    get download_drive_item_url(@drive_item), headers: request_headers

    assert_response :ok
    assert_includes response.headers["Content-Disposition"], "filename*="
  end

  test "監査ログ保存失敗時は配信を拒否する" do
    sign_in @user
    failure = AuditLogs::Recorder::Result.failure("監査ログの保存に失敗しました")
    recorder = Struct.new(:result) do
      def call
        result
      end
    end.new(failure)

    original_new = AuditLogs::Recorder.method(:new)
    AuditLogs::Recorder.define_singleton_method(:new) do |*|
      recorder
    end

    begin
      get preview_drive_item_url(@drive_item), headers: request_headers
    ensure
      AuditLogs::Recorder.define_singleton_method(:new, original_new)
    end

    assert_response :service_unavailable
    assert_nil response.headers["X-Accel-Redirect"]
  end

  private

  def pdf_payload
    "%PDF-1.4 sample delivery file"
  end

  def request_headers
    {
      "REMOTE_ADDR" => "203.0.113.10",
      "HTTP_USER_AGENT" => "DeliveryTest/1.0"
    }
  end
end
