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
    sign_in_with_magic_link @user

    get api_v1_me_url
    assert_response :ok
    assert_equal @user.id, response.parsed_body.dig("data", "id")

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
    assert_nil body["generated_password"]

    get api_v1_me_url
    assert_response :ok
    assert_equal @user.id, response.parsed_body.dig("data", "id")

    get api_v1_external_shares_url
    assert_response :ok
    assert_nil JSON.parse(response.body).first["share_url"]

    get api_v1_external_share_url(body.fetch("id"))
    assert_response :ok
    detail = JSON.parse(response.body)
    assert_nil detail["share_url"]
    assert_nil detail["raw_token"]
    assert_nil detail["generated_password"]
  end

  test "パスワード保護ありの作成レスポンスだけが生成パスワードを返す" do
    sign_in_with_magic_link @user

    post api_v1_external_shares_url, params: {
      external_share: {
        name: "公開",
        drive_item_ids: [ @drive_item.id ],
        folder_share_mode: "snapshot",
        password_protected: true
      }
    }

    assert_response :created
    body = JSON.parse(response.body)
    generated_password = body.fetch("generated_password")
    assert_match(/\A[ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789]{16}\z/, generated_password)

    share = ExternalShare.find(body.fetch("id"))
    assert_not_equal generated_password, share.password_digest
    assert share.authenticate(generated_password)

    get api_v1_external_shares_url
    assert_response :ok
    assert_nil JSON.parse(response.body).first["generated_password"]

    get api_v1_external_share_url(share)
    assert_response :ok
    assert_nil JSON.parse(response.body)["generated_password"]
  end

  test "作成リクエストはログイン必須" do
    post api_v1_external_shares_url, params: {
      external_share: {
        name: "公開",
        drive_item_ids: [ @drive_item.id ],
        folder_share_mode: "snapshot"
      }
    }

    assert_response :unauthorized
  end

  test "パスワード解除前に共有内容を返さない" do
    raw_token, = create_share!(password_protected: true)

    get "/api/v1/public/shares/#{raw_token}"

    assert_response :ok
    assert_equal({ "password_required" => true }, JSON.parse(response.body))
    assert_no_match @drive_item.name, response.body
  end

  test "正しいパスワードで解除でき間違ったパスワードでは解除できない" do
    raw_token, generated_password = create_share!(password_protected: true)

    post "/api/v1/public/shares/#{raw_token}/unlock", params: { password: "wrong-password" }
    assert_response :unauthorized
    assert_equal "invalid_share_password", response.parsed_body.dig("error", "code")
    assert_equal "パスワードが正しくありません", response.parsed_body.dig("error", "message")

    post "/api/v1/public/shares/#{raw_token}/unlock", params: { password: generated_password }
    assert_response :ok
    assert_equal true, response.parsed_body.fetch("unlocked")

    get "/api/v1/public/shares/#{raw_token}"
    assert_response :ok
    assert_equal @drive_item.filename, response.parsed_body.fetch("items").first.fetch("name")
  end

  test "作成レスポンスで返したパスワードをJSONで送ると解除Cookieを発行して閲覧できる" do
    https!
    raw_token, generated_password = create_share!(password_protected: true)

    post "/api/v1/public/shares/#{raw_token}/unlock",
      params: { password: generated_password }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    assert_response :ok
    assert_equal true, response.parsed_body.fetch("unlocked")
    set_cookie = response.headers.fetch("Set-Cookie")
    assert_match(/(?:^|;\s*)httponly(?:;|$)/i, set_cookie)
    assert_match(/(?:^|;\s*)secure(?:;|$)/i, set_cookie)
    assert_match(/(?:^|;\s*)samesite=lax(?:;|$)/i, set_cookie)

    get "/api/v1/public/shares/#{raw_token}", headers: { "Accept" => "application/json" }
    assert_response :ok
    assert_equal @drive_item.filename, response.parsed_body.fetch("items").first.fetch("name")
  end

  test "期限切れと停止済みはunlockで判別可能な安全コードを返す" do
    raw_token, _generated_password, share = create_share!(password_protected: true, return_share: true)

    share.update_columns(expires_at: 1.minute.ago)
    post "/api/v1/public/shares/#{raw_token}/unlock", params: { password: "anything" }
    assert_response :not_found
    assert_equal "share_expired", response.parsed_body.dig("error", "code")
    assert_equal "この共有リンクは利用できません", response.parsed_body.dig("error", "message")

    share.update_columns(expires_at: nil, revoked_at: Time.current)
    post "/api/v1/public/shares/#{raw_token}/unlock", params: { password: "anything" }
    assert_response :not_found
    assert_equal "share_revoked", response.parsed_body.dig("error", "code")
    assert_equal "この共有リンクは利用できません", response.parsed_body.dig("error", "message")
  end

  test "再発行後は旧パスワードが無効になり新パスワードで解除できる" do
    raw_token, old_password, share = create_share!(password_protected: true, return_share: true)
    sign_in_with_magic_link @user

    post "/api/v1/external_shares/#{share.id}/regenerate_password"
    assert_response :ok
    new_password = response.parsed_body.fetch("generated_password")
    assert_not_equal old_password, new_password
    assert_not_equal new_password, share.reload.password_digest

    post "/api/v1/public/shares/#{raw_token}/unlock", params: { password: old_password }
    assert_response :unauthorized

    post "/api/v1/public/shares/#{raw_token}/unlock", params: { password: new_password }
    assert_response :ok
  end

  test "生成パスワードは監査ログに保存しない" do
    sign_in_with_magic_link @user

    post api_v1_external_shares_url, params: {
      external_share: {
        name: "公開",
        drive_item_ids: [ @drive_item.id ],
        folder_share_mode: "snapshot",
        password_protected: true
      }
    }

    assert_response :created
    generated_password = response.parsed_body.fetch("generated_password")
    audit_payloads = AuditEvent.where(action: "external_share.created").map { |event| event.metadata.to_json }
    assert audit_payloads.present?
    assert audit_payloads.none? { |payload| payload.include?(generated_password) }
  end

  test "ログインなしで有効な共有を閲覧できる" do
    raw_token, = create_share!

    get "/api/v1/public/shares/#{raw_token}"

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "公開", body.fetch("name")
    assert_equal @drive_item.filename, body.fetch("items").first.fetch("name")
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "allow_download=falseでは個別ダウンロードできない" do
    raw_token, = create_share!(allow_download: false)

    get "/api/v1/public/shares/#{raw_token}/items/#{@drive_item.id}/download"

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  test "停止済み共有は外部から利用できない" do
    raw_token, = create_share!
    ExternalShare.last.update!(revoked_at: Time.current)

    get "/api/v1/public/shares/#{raw_token}"

    assert_response :not_found
  end

  test "HTMLは外部公開プレビューとしてインライン表示しない" do
    @drive_item.update_columns(extension: "html", content_type: "text/html")
    raw_token, = create_share!

    get "/api/v1/public/shares/#{raw_token}/items/#{@drive_item.id}/preview"

    assert_response :not_found
    assert_nil response.headers["X-Accel-Redirect"]
  end

  private

  def create_share!(password_protected: false, allow_download: true, return_share: false)
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "公開",
        drive_item_ids: [ @drive_item.id ],
        folder_share_mode: "snapshot",
        allow_download: allow_download,
        allow_bulk_download: false,
        password_protected: password_protected
      }
    ).call
    assert result.success?, result.error_message
    values = [ result.raw_token, result.generated_password ]
    values << result.external_share if return_share
    values
  end

  def pdf_payload
    "%PDF-1.4 external share"
  end
end
