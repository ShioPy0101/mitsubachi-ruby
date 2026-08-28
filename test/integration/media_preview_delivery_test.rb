require "test_helper"
require "fileutils"

class MediaPreviewDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @item = drive_items(:child_file)
    @storage_key = "thumbnail-delivery-#{SecureRandom.uuid}.jpg"
    @item.update_columns(
      storage_key: @storage_key,
      blob_path: DriveItem.storage_relative_path_for(@storage_key),
      content_type: "image/jpeg",
      file_hash: Digest::SHA256.hexdigest("thumbnail-original-#{SecureRandom.uuid}"),
      file_size: 8,
      deleted_at: nil,
      purged_at: nil
    )
    FileUtils.mkdir_p(@item.absolute_storage_path.dirname)
    File.binwrite(@item.absolute_storage_path, "original")
    write_cached_preview(@item)
  end

  teardown do
    FileUtils.rm_f(@item.absolute_storage_path)
    FileUtils.rm_f(MediaPreviews::CachePath.new(drive_item: @item).absolute_path)
  end

  test "画像thumbnailはRailsで本文を読まずNginxへ委譲する" do
    sign_in @user

    assert_difference "DriveItemAccessLog.where(action: 'preview').count", 1 do
      get thumbnail_path(@item)
    end

    assert_response :ok
    assert_match %r{\A/internal/previews/organization-#{@item.organization_id}/drive-item-#{@item.id}/}, response.headers["X-Accel-Redirect"]
    assert_equal "image/jpeg", response.headers["Content-Type"]
    assert_includes response.headers["Cache-Control"], "private"
    assert_includes response.headers["Cache-Control"], "max-age=86400"
    assert response.body.empty?
  end

  test "動画thumbnailも生成済み代表frameを配信する" do
    @item.update_columns(content_type: "video/mp4")
    write_cached_preview(@item)
    sign_in @user

    get thumbnail_path(@item)

    assert_response :ok
    assert_equal "image/jpeg", response.headers["Content-Type"]
  end

  test "ETag一致時は生成と監査を行わず304を返す" do
    sign_in @user
    get thumbnail_path(@item)
    etag = response.headers.fetch("ETag")

    assert_no_difference "DriveItemAccessLog.count" do
      sign_in @user
      get thumbnail_path(@item), headers: { "If-None-Match" => etag }
    end

    assert_response :not_modified
    assert_nil response.headers["X-Accel-Redirect"]
  end

  test "非対応mediaは明確なfailureを返す" do
    @item.update_columns(content_type: "application/pdf")
    sign_in @user

    get thumbnail_path(@item)

    assert_response :unsupported_media_type
    assert_equal "unsupported_media_type", response.parsed_body.dig("error", "code")
  end

  test "別organizationのitemは取得できない" do
    sign_in @user

    get thumbnail_path(drive_items(:two))

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  test "存在しないitemは取得できない" do
    sign_in @user

    get thumbnail_path(Struct.new(:id).new(9_999_999_999))

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  test "trashとpurge済みitemは取得できない" do
    sign_in @user
    @item.update_columns(deleted_at: Time.current)
    get thumbnail_path(@item)
    assert_response :not_found

    @item.update_columns(purged_at: Time.current)
    sign_in @user
    get thumbnail_path(@item)
    assert_response :not_found
  end

  test "share thumbnailはshare認可を通り範囲外itemを拒否する" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "画像共有",
        drive_item_ids: [ @item.id ],
        folder_share_mode: "snapshot",
        allow_download: true,
        allow_bulk_download: false
      }
    ).call
    assert result.success?, result.error_message

    get "/api/v1/public/shares/#{result.raw_token}/items/#{@item.id}/thumbnail"
    assert_response :ok
    assert_equal "external_share", DriveItemAccessLog.order(:id).last.actor_kind

    get "/api/v1/public/shares/#{result.raw_token}/items/#{drive_items(:two).id}/thumbnail"
    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  test "password保護shareは解除前にthumbnailを返さない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "保護された画像共有",
        drive_item_ids: [ @item.id ],
        folder_share_mode: "snapshot",
        allow_download: true,
        allow_bulk_download: false,
        password_protected: true
      }
    ).call
    assert result.success?, result.error_message

    get "/api/v1/public/shares/#{result.raw_token}/items/#{@item.id}/thumbnail"

    assert_response :unauthorized
    assert_equal({ "password_required" => true }, response.parsed_body)
    assert_nil response.headers["X-Accel-Redirect"]
  end

  private

  def thumbnail_path(item)
    "/api/v1/organizations/#{@user.organization_id}/drive_items/#{item.id}/thumbnail"
  end

  def write_cached_preview(item)
    path = MediaPreviews::CachePath.new(drive_item: item).absolute_path
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, "jpeg-preview")
  end
end
