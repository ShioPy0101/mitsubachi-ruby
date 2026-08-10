require "test_helper"
require "fileutils"
require "digest"

class DriveItemDeliveryTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:one)
    @drive_item = drive_items(:child_file)
    @other_item = drive_items(:two)
    @storage_key = "#{SecureRandom.uuid}.pdf"

    FileUtils.mkdir_p(DriveItem.storage_root.join("drive_items"))
    @drive_item.update_columns(
      storage_key: @storage_key,
      blob_path: DriveItem.storage_relative_path_for(@storage_key),
      file_hash: Digest::SHA256.hexdigest(pdf_payload),
      file_size: pdf_payload.bytesize,
      content_type: "application/pdf"
    )
    File.binwrite(@drive_item.absolute_storage_path, pdf_payload)
  end

  teardown do
    travel_back
    FileUtils.rm_f(@drive_item.absolute_storage_path)
  end

  test "未認証では配信できない" do
    get preview_api_v1_drive_item_url(@drive_item)

    assert_response :unauthorized
  end

  test "preview は同じ organization のファイルを inline 配信する" do
    sign_in @user

    assert_difference "DriveItemAccessLog.count", 1 do
      assert_no_difference "OperationLog.count" do
        get preview_api_v1_drive_item_url(@drive_item), headers: request_headers
      end
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

  test "preview は既存の 0600 ファイルを X-Accel 用に補正してから委譲する" do
    File.chmod(0o600, @drive_item.absolute_storage_path)
    sign_in @user

    get preview_api_v1_drive_item_url(@drive_item), headers: request_headers

    assert_response :ok
    assert_equal "/internal/storage/drive_items/#{@drive_item.storage_key}", response.headers["X-Accel-Redirect"]
    assert_equal 0o644, File.stat(@drive_item.absolute_storage_path).mode & 0o777
    assert_equal pdf_payload, File.binread(@drive_item.absolute_storage_path)
  end

  test "同じ organization の別ユーザーによる preview は操作ユーザーのアクセスログを記録する" do
    viewer = User.create!(
      organization: @user.organization,
      email: "preview-viewer@example.com",
      name: "Preview Viewer",
      password: "password123"
    )
    viewer.organization_memberships.create!(
      organization: @user.organization,
      role: :member,
      status: :active
    )
    sign_in viewer

    assert_difference "DriveItemAccessLog.where(action: 'preview', user: viewer).count", 1 do
      assert_no_difference "OperationLog.count" do
        get preview_api_v1_drive_item_url(@drive_item), headers: request_headers
      end
    end

    log = DriveItemAccessLog.where(action: "preview", user: viewer).order(:id).last
    assert_equal @user.organization, log.organization
    assert_equal @drive_item, log.drive_item
  end

  test "download は attachment を返す" do
    sign_in @user

    assert_difference "DriveItemAccessLog.count", 1 do
      get download_api_v1_drive_item_url(@drive_item), headers: request_headers
    end

    assert_response :ok
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_equal "download", DriveItemAccessLog.order(:id).last.action
  end

  test "stream は inline を返す" do
    sign_in @user

    assert_difference "DriveItemAccessLog.count", 1 do
      get stream_api_v1_drive_item_url(@drive_item), headers: request_headers.merge("Range" => "bytes=0-10")
    end

    assert_response :ok
    assert_match(/\Ainline;/, response.headers["Content-Disposition"])
    assert_equal "stream", DriveItemAccessLog.order(:id).last.action
  end

  test "動画の Range リクエストが複数回発生してもアクセスログを大量作成しない" do
    sign_in @user

    assert_difference "DriveItemAccessLog.where(action: 'stream').count", 1 do
      assert_no_difference "OperationLog.count" do
        get stream_api_v1_drive_item_url(@drive_item), headers: request_headers.merge("Range" => "bytes=0-10")
        assert_response :ok
        sign_in @user
        get stream_api_v1_drive_item_url(@drive_item), headers: request_headers.merge("Range" => "bytes=11-20")
        assert_response :ok
        sign_in @user
        get stream_api_v1_drive_item_url(@drive_item), headers: request_headers.merge("Range" => "bytes=21-30")
        assert_response :ok
      end
    end
  end

  test "他 organization のファイルは配信できない" do
    sign_in @user

    get preview_api_v1_drive_item_url(@other_item), headers: request_headers

    assert_response :not_found
  end

  test "削除済みファイルは配信できない" do
    sign_in @user
    @drive_item.update!(deleted_at: Time.current)

    get preview_api_v1_drive_item_url(@drive_item), headers: request_headers

    assert_response :not_found
  end

  test "危険な storage_key は拒否する" do
    sign_in @user
    @drive_item.update_columns(storage_key: "../secret.pdf", blob_path: "drive_items/../secret.pdf")

    get preview_api_v1_drive_item_url(@drive_item), headers: request_headers

    assert_response :not_found
  end

  test "実ファイルが存在しない場合は配信できない" do
    sign_in @user
    FileUtils.rm_f(@drive_item.absolute_storage_path)

    assert_difference "SystemEvent.where(event_type: 'storage.file_missing').count", 1 do
      get preview_api_v1_drive_item_url(@drive_item), headers: request_headers
    end

    assert_response :not_found
  end

  test "日本語ファイル名でも Content-Disposition を生成する" do
    sign_in @user
    @drive_item.update!(name: "日本語資料")

    get download_api_v1_drive_item_url(@drive_item), headers: request_headers

    assert_response :ok
    assert_includes response.headers["Content-Disposition"], "filename*="
  end

  test "操作履歴保存失敗時は配信を拒否する" do
    sign_in @user
    failure = DriveItemAccessLogs::Recorder::Result.failure("ファイルアクセス履歴の保存に失敗しました")
    recorder = Struct.new(:result) do
      def call
        result
      end
    end.new(failure)

    original_new = DriveItemAccessLogs::Recorder.method(:new)
    DriveItemAccessLogs::Recorder.define_singleton_method(:new) do |*|
      recorder
    end

    begin
      get preview_api_v1_drive_item_url(@drive_item), headers: request_headers
    ensure
      DriveItemAccessLogs::Recorder.define_singleton_method(:new, original_new)
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
