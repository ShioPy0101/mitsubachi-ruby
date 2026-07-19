require "test_helper"
require "tempfile"
require "fileutils"
require "stringio"
require "zip"

class DriveItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @other_item = drive_items(:two)
    @root = drive_items(:one)
    @file = drive_items(:child_file)
    @child_folder = drive_items(:child_folder)
    @grandchild_folder = drive_items(:grandchild_folder)
    @deleted_folder = drive_items(:deleted_folder)
    @deleted_report = drive_items(:deleted_report)

    @organization = @user.organization
    @tempfiles = []
    @storage_paths = []
  end

  teardown do
    @tempfiles.each do |tempfile|
      tempfile.close
      tempfile.unlink
    end

    @storage_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "should get index" do
    get api_v1_drive_items_url
    assert_response :unauthorized
  end

  test "should get show" do
    get api_v1_drive_item_url(drive_items(:one))
    assert_response :unauthorized
  end

  test "他組織のアイテムへアクセスできない" do
    sign_in @user

    get api_v1_drive_item_url(@other_item)

    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
    assert response.parsed_body.dig("error", "request_id").present?
  end

  test "削除済みアイテムは show できない" do
    sign_in @user

    get api_v1_drive_item_url(@deleted_folder)

    assert_response :not_found
  end

  test "削除済みアイテムは update できない" do
    sign_in @user

    patch api_v1_drive_item_url(@deleted_folder), params: { name: "restored_name" }

    assert_response :not_found
    assert_equal "deleted_folder", @deleted_folder.reload.name
  end

  test "削除済みアイテムは destroy できない" do
    sign_in @user

    delete api_v1_drive_item_url(@deleted_folder)

    assert_response :not_found
    assert @deleted_folder.reload.deleted_at.present?
  end

  test "削除済みアイテムを restore できる" do
    sign_in @user

    assert_difference "AuditEvent.where(action: 'drive_item.restore').count", 1 do
      post restore_api_v1_drive_item_url(@deleted_folder)
    end

    assert_response :ok
    assert_nil @deleted_folder.reload.deleted_at
  end

  test "active なアイテムは restore できない" do
    sign_in @user

    post restore_api_v1_drive_item_url(@root)

    assert_response :not_found
  end

  test "update でルート直下へ移動できる" do
    sign_in @user

    assert_difference "AuditEvent.where(action: 'drive_item.update').count", 1 do
      patch api_v1_drive_item_url(@child_folder), params: { parent_id: "" }
    end

    assert_response :ok
    assert_nil @child_folder.reload.parent_id
  end

  test "ファイルを親に指定できない" do
    sign_in @user

    patch api_v1_drive_item_url(@child_folder), params: { parent_id: @file.id }

    assert_response :unprocessable_entity
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "自分自身を親に指定できない" do
    sign_in @user

    patch api_v1_drive_item_url(@child_folder), params: { parent_id: @child_folder.id }

    assert_response :unprocessable_entity
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "子孫フォルダへ移動できない" do
    sign_in @user

    patch api_v1_drive_item_url(@child_folder), params: { parent_id: @grandchild_folder.id }

    assert_response :unprocessable_entity
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "show はルートから現在地までのbreadcrumbsを返す" do
    sign_in @user
    h1 = create_directory(name: "h1")
    h2 = create_directory(name: "h2", parent: h1)
    h3 = create_directory(name: "h3", parent: h2)
    world = create_directory(name: "world", parent: h3)

    get api_v1_drive_item_url(world)

    assert_response :ok
    assert_equal(
      [
        { "id" => nil, "name" => "共有ドライブ" },
        { "id" => h1.id, "name" => "h1" },
        { "id" => h2.id, "name" => "h2" },
        { "id" => h3.id, "name" => "h3" },
        { "id" => world.id, "name" => "world" }
      ],
      response.parsed_body.fetch("breadcrumbs")
    )
  end

  test "move API は移動後の項目とrequest_idを返し監査ログを記録する" do
    sign_in @user
    destination = create_directory(name: "destination")

    assert_difference "AuditEvent.where(action: 'drive_item.move').count", 1 do
      patch move_api_v1_drive_item_url(@file), params: { parent_id: destination.id }
    end

    assert_response :ok
    assert_equal destination.id, @file.reload.parent_id
    assert_equal @file.id, response.parsed_body.dig("data", "id")
    assert response.parsed_body.fetch("request_id").present?
    event = AuditEvent.where(action: "drive_item.move").last
    assert_equal [ @root.id, destination.id ], event.change_set["parent_id"]
  end

  test "move API は別organizationの親を拒否する" do
    sign_in @user

    patch move_api_v1_drive_item_url(@file), params: { parent_id: @other_item.id }

    assert_response :not_found
    assert_equal "invalid_parent", response.parsed_body.dig("error", "code")
    assert_equal @root.id, @file.reload.parent_id
  end

  test "move API は自分自身への移動を拒否する" do
    sign_in @user

    patch move_api_v1_drive_item_url(@child_folder), params: { parent_id: @child_folder.id }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "move API は子孫への移動を拒否する" do
    sign_in @user

    patch move_api_v1_drive_item_url(@child_folder), params: { parent_id: @grandchild_folder.id }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "move API は削除済みフォルダーへの移動を拒否する" do
    sign_in @user

    patch move_api_v1_drive_item_url(@file), params: { parent_id: @deleted_folder.id }

    assert_response :not_found
    assert_equal "invalid_parent", response.parsed_body.dig("error", "code")
    assert_equal @root.id, @file.reload.parent_id
  end

  test "move API は同じ親への移動を拒否する" do
    sign_in @user

    patch move_api_v1_drive_item_url(@file), params: { parent_id: @root.id }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal @root.id, @file.reload.parent_id
  end

  test "move API は同名衝突を409で返す" do
    sign_in @user
    destination = create_directory(name: "destination")
    storage_key = "#{SecureRandom.uuid}.#{@file.extension}"
    write_storage_file(storage_key, "duplicate")
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: destination,
      name: @file.name,
      item_type: "file",
      extension: @file.extension,
      blob_path: storage_key,
      storage_key: storage_key
    )

    patch move_api_v1_drive_item_url(@file), params: { parent_id: destination.id }

    assert_response :conflict
    assert_equal "duplicate_name", response.parsed_body.dig("error", "code")
    assert_equal "name", response.parsed_body.dig("error", "details", "field")
    assert_equal @root.id, @file.reload.parent_id
  end

  test "bulk_move は途中失敗時にロールバックする" do
    sign_in @user
    movable = DriveItem.create!(
      organization: @user.organization,
      owner_user: @user,
      parent: @root,
      name: "movable",
      item_type: "directory"
    )
    ancestor = DriveItem.create!(
      organization: @user.organization,
      owner_user: @user,
      parent: @root,
      name: "ancestor",
      item_type: "directory"
    )
    descendant = DriveItem.create!(
      organization: @user.organization,
      owner_user: @user,
      parent: ancestor,
      name: "descendant",
      item_type: "directory"
    )

    post bulk_move_api_v1_drive_items_url, params: {
      drive_item_ids: [ movable.id, ancestor.id ],
      parent_id: descendant.id
    }

    assert_response :unprocessable_entity
    assert_equal @root.id, movable.reload.parent_id
    assert_equal @root.id, ancestor.reload.parent_id
  end

  test "bulk_move は同名衝突時にロールバックし409を返す" do
    sign_in @user
    movable = create_directory(name: "movable", parent: @root)
    destination = create_directory(name: "destination")
    create_directory(name: "movable", parent: destination)

    post bulk_move_api_v1_drive_items_url, params: {
      drive_item_ids: [ movable.id ],
      parent_id: destination.id
    }

    assert_response :conflict
    assert_equal "duplicate_name", response.parsed_body.dig("error", "code")
    assert_equal @root.id, movable.reload.parent_id
  end

  test "bulk_move は ids パラメータでも移動できる" do
    sign_in @user
    destination = create_directory(name: "ids_destination")

    post bulk_move_api_v1_drive_items_url, params: {
      ids: [ @file.id ],
      parent_id: destination.id
    }

    assert_response :ok
    assert_equal destination.id, @file.reload.parent_id
  end

  test "DB保存失敗時にアップロード済みファイルが削除される" do
    sign_in @user
    original_save = DriveItem.instance_method(:save)
    original_build_storage_key = Api::V1::DriveItemsController.instance_method(:build_storage_key)
    storage_key = "#{SecureRandom.uuid}.txt"
    storage_path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))

    DriveItem.define_method(:save) do |*args, **kwargs|
      false
    end
    Api::V1::DriveItemsController.define_method(:build_storage_key) do |_extension|
      storage_key
    end

    post api_v1_drive_items_url, params: {
      name: "orphan",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("orphan.txt", "orphan")
    }

    assert_response :unprocessable_entity
    assert_not File.exist?(storage_path)
  ensure
    DriveItem.define_method(:save, original_save)
    Api::V1::DriveItemsController.define_method(:build_storage_key, original_build_storage_key)
  end

  test "ゴミ箱内に同名アイテムがあっても新規作成できる" do
    sign_in @user

    assert_difference "DriveItem.count", 1 do
      assert_difference "AuditEvent.where(action: 'drive_item.create').count", 1 do
        post api_v1_drive_items_url, params: {
        name: @deleted_report.name,
        item_type: "file",
        parent_id: @root.id,
        file: uploaded_file("#{@deleted_report.name}.txt", "new")
      }, headers: { "REMOTE_ADDR" => "198.51.100.10" }
      end
    end

    assert_response :created
    created = DriveItem.order(:id).last
    assert_nil created.deleted_at
    assert_equal @deleted_report.name, created.name
    assert_equal "198.51.100.10", created.upload_ip_address
  ensure
    cleanup_created_file(created) if defined?(created) && created&.persisted?
  end

  test "index は作成者表示名を含めメールアドレスを含めない" do
    sign_in @user

    get api_v1_drive_items_url, params: { parent_id: @root.id }

    assert_response :ok
    item = response.parsed_body.find { |entry| entry.fetch("id") == @file.id }
    assert_equal "User One", item.fetch("owner_display_name")
    assert_not_includes item.keys, "owner_email"
  end

  test "search は名前と拡張子と作成者表示名で検索できる" do
    sign_in @user
    @user.update!(display_name: "佐藤")
    create_file_item(name: "meeting_notes.txt", body: "notes", parent: @root)

    get search_api_v1_drive_items_url, params: { q: "佐藤", scope: "organization" }

    assert_response :ok
    names = response.parsed_body.fetch("data").pluck("name")
    assert_includes names, "meeting_notes.txt"

    sign_in @user
    get search_api_v1_drive_items_url, params: { q: "pdf", scope: "organization" }

    assert_response :ok
    assert_includes response.parsed_body.fetch("data").pluck("name"), @file.name
  end

  test "search は他organizationと削除済みアイテムを含めない" do
    sign_in @user

    get search_api_v1_drive_items_url, params: { q: "sample", scope: "organization" }

    assert_response :ok
    ids = response.parsed_body.fetch("data").pluck("id")
    assert_not_includes ids, @other_item.id

    sign_in @user
    get search_api_v1_drive_items_url, params: { q: @deleted_report.name, scope: "organization" }

    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
  end

  test "search はページネーションメタを返す" do
    sign_in @user
    create_file_item(name: "page-one.txt", body: "one", parent: @root)
    create_file_item(name: "page-two.txt", body: "two", parent: @root)

    get search_api_v1_drive_items_url, params: { q: "page", scope: "organization", per_page: 1, page: 2 }

    assert_response :ok
    assert_equal 1, response.parsed_body.fetch("data").size
    assert_equal 2, response.parsed_body.dig("meta", "current_page")
    assert_equal 2, response.parsed_body.dig("meta", "total_count")
  end

  test "重複名の作成は409と機械判定可能なコードを返す" do
    sign_in @user

    post api_v1_drive_items_url, params: {
      name: @file.name,
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("#{@file.name}.#{@file.extension}", "duplicate")
    }

    assert_response :conflict
    assert_equal "duplicate_name", response.parsed_body.dig("error", "code")
    assert_equal "name", response.parsed_body.dig("error", "details", "field")
    assert_equal @file.name, response.parsed_body.dig("error", "details", "conflicting_name")
    assert response.parsed_body.dig("error", "request_id").present?
  end

  test "複数ファイルをZIPで取得できる" do
    sign_in @user
    file_a = create_file_item(name: "alpha.txt", body: "alpha")
    file_b = create_file_item(name: "beta.txt", body: "beta")

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ file_a.id, file_b.id ] }

    assert_response :ok
    assert_equal "application/zip", response.media_type
    assert_match(/attachment;/, response.headers["Content-Disposition"])

    entries = zip_entries(response.body)
    assert_equal "alpha", entries.fetch("alpha.txt")
    assert_equal "beta", entries.fetch("beta.txt")
    assert_equal 2, DriveItemAccessLog.where(action: "bulk_download").count
  end

  test "フォルダ構造がZIP内で維持される" do
    sign_in @user
    folder = create_directory(name: "docs")
    create_file_item(name: "readme.txt", parent: folder, body: "readme")

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ folder.id ] }

    assert_response :ok
    assert_equal "readme", zip_entries(response.body).fetch("docs/readme.txt")
  end

  test "サブフォルダ内のファイルが含まれる" do
    sign_in @user
    folder = create_directory(name: "docs")
    subfolder = create_directory(name: "nested", parent: folder)
    create_file_item(name: "deep.txt", parent: subfolder, body: "deep")

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ folder.id ] }

    assert_response :ok
    assert_equal "deep", zip_entries(response.body).fetch("docs/nested/deep.txt")
  end

  test "他組織のアイテムが含まれない" do
    sign_in @user
    own_file = create_file_item(name: "own.txt", body: "own")
    other_file = drive_items(:two)
    write_storage_file(other_file.storage_key, "other")

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ own_file.id, other_file.id ] }

    assert_response :ok
    entries = zip_entries(response.body)
    assert_equal [ "own.txt" ], entries.keys
  end

  test "削除済みアイテムが含まれない" do
    sign_in @user
    own_file = create_file_item(name: "own.txt", body: "own")
    deleted_file = create_file_item(name: "deleted.txt", body: "deleted", deleted_at: Time.current)

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ own_file.id, deleted_file.id ] }

    assert_response :ok
    entries = zip_entries(response.body)
    assert_equal [ "own.txt" ], entries.keys
  end

  test "存在しない物理ファイルを安全に処理できる" do
    sign_in @user
    missing_file = create_file_item(name: "missing.txt", body: "missing")
    FileUtils.rm_f(missing_file.absolute_storage_path)

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ missing_file.id ] }

    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
    assert_equal "実ファイルが見つからないファイルが含まれています", response.parsed_body.dig("error", "message")
    assert response.parsed_body.dig("error", "request_id").present?
  end

  test "ファイル名にパス区切り文字があってもZIP Slipが起きない" do
    sign_in @user
    unsafe_file = create_file_item(name: "../secret.txt", body: "secret")

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ unsafe_file.id ] }

    assert_response :ok
    entries = zip_entries(response.body)
    assert_equal [ "___secret.txt" ], entries.keys
    assert entries.keys.none? { |name| name.start_with?("/") || name.include?("../") }
  end

  test "ZIP内の同名衝突は連番で回避する" do
    sign_in @user
    parent_a = create_directory(name: "parent_a")
    parent_b = create_directory(name: "parent_b")
    folder_a = create_directory(name: "folder", parent: parent_a)
    folder_b = create_directory(name: "folder", parent: parent_b)
    create_file_item(name: "same.txt", parent: folder_a, body: "a")
    create_file_item(name: "same.txt", parent: folder_b, body: "b")

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ folder_a.id, folder_b.id ] }

    assert_response :ok
    entries = zip_entries(response.body)
    assert_equal "a", entries.fetch("folder/same.txt")
    assert_equal "b", entries.fetch("folder/same (2).txt")
  end

  test "ZIP生成失敗時に一時ファイルが残らない" do
    sign_in @user
    file = create_file_item(name: "broken.txt", body: "broken")
    captured_zip_path = nil
    original_open = Zip::OutputStream.method(:open)

    Zip::OutputStream.define_singleton_method(:open) do |zip_path, *|
      captured_zip_path = zip_path
      raise "zip failure"
    end

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ file.id ] }

    assert_response :unprocessable_entity
    assert captured_zip_path
    assert_not File.exist?(captured_zip_path)
  ensure
    Zip::OutputStream.define_singleton_method(:open, original_open)
  end

  test "ZIP送信処理で例外が発生した場合に安全な一時ZIPだけが削除される" do
    sign_in @user
    file = create_file_item(name: "send_failure.txt", body: "send failure")
    original_send_zip_file = Api::V1::DriveItemsController.instance_method(:send_zip_file)
    captured_result = nil

    Api::V1::DriveItemsController.define_method(:send_zip_file) do |result|
      captured_result = result
      raise "send failure"
    end

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [ file.id ] }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal "ZIPファイルを送信できませんでした", response.parsed_body.dig("error", "message")
    assert captured_result
    assert_not File.exist?(captured_result.zip_path)
  ensure
    Api::V1::DriveItemsController.define_method(:send_zip_file, original_send_zip_file)
  end

  test "対象IDが空の場合にエラーになる" do
    sign_in @user

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [] }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
    assert_equal "対象が指定されていません", response.parsed_body.dig("error", "message")
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

  def cleanup_created_file(drive_item)
    return unless drive_item.file? && drive_item.storage_key.present?

    FileUtils.rm_f(drive_item.absolute_storage_path)
  end

  def create_directory(name:, parent: nil)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: parent,
      name: name,
      item_type: "directory"
    )
  end

  def create_file_item(name:, body:, parent: nil, deleted_at: nil)
    extension = File.extname(name).delete_prefix(".").presence || "txt"
    storage_key = "#{SecureRandom.uuid}.#{extension}"
    write_storage_file(storage_key, body)

    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: parent,
      name: name,
      item_type: "file",
      extension: extension,
      blob_path: storage_key,
      storage_key: storage_key,
      deleted_at: deleted_at
    )
  end

  def write_storage_file(storage_key, body)
    path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body)
    @storage_paths << path
  end

  def zip_entries(body)
    entries = {}

    Zip::File.open_buffer(StringIO.new(body)) do |zip|
      zip.each do |entry|
        entries[entry.name] = entry.get_input_stream.read
      end
    end

    entries
  end
end
