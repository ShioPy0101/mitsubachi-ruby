require "test_helper"
require "digest"
require "fileutils"

class ExternalSharesApiTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @drive_item = drive_items(:child_file)
    @storage_key = "external-share-#{SecureRandom.uuid}.pdf"
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
    FileUtils.rm_f(@drive_item.absolute_storage_path)
  end

  test "作成レスポンスだけが共有URLを返す" do
    sign_in @user

    post api_v1_external_shares_url, params: {
      external_share: {
        name: "公開",
        drive_item_ids: [ @drive_item.id ],
        folder_share_mode: "snapshot",
        allow_download: true,
        allow_bulk_download: false
      }
    }

    assert_response :created
    body = JSON.parse(response.body)
    assert_match(%r{/share/}, body.fetch("share_url"))

    get api_v1_external_shares_url
    assert_response :ok
    assert_nil JSON.parse(response.body).first["share_url"]
  end

  test "パスワード解除前に共有内容を返さない" do
    raw_token = create_share!(password: "secret")

    get "/api/v1/public/shares/#{raw_token}"

    assert_response :ok
    assert_equal({ "password_required" => true }, JSON.parse(response.body))
    assert_no_match @drive_item.name, response.body
  end

  test "ログインなしで有効な共有を閲覧できる" do
    raw_token = create_share!

    get "/api/v1/public/shares/#{raw_token}"

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "公開", body.fetch("name")
    assert_equal @drive_item.filename, body.fetch("items").first.fetch("name")
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "allow_download=falseでは個別ダウンロードできない" do
    raw_token = create_share!(allow_download: false)

    get "/api/v1/public/shares/#{raw_token}/items/#{@drive_item.id}/download"

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  test "停止済み共有は外部から利用できない" do
    raw_token = create_share!
    ExternalShare.last.update!(revoked_at: Time.current)

    get "/api/v1/public/shares/#{raw_token}"

    assert_response :not_found
  end

  test "HTMLは外部公開プレビューとしてインライン表示しない" do
    @drive_item.update_columns(extension: "html", content_type: "text/html")
    raw_token = create_share!

    get "/api/v1/public/shares/#{raw_token}/items/#{@drive_item.id}/preview"

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  private

  def create_share!(password: nil, allow_download: true)
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "公開",
        drive_item_ids: [ @drive_item.id ],
        folder_share_mode: "snapshot",
        allow_download: allow_download,
        allow_bulk_download: false,
        password: password
      }
    ).call
    assert result.success?, result.error_message
    result.raw_token
  end

  def pdf_payload
    "%PDF-1.4 external share"
  end
end
