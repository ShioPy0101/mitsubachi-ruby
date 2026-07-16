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
        }
      end
    end

    assert_response :created
    created = DriveItem.order(:id).last
    assert_nil created.deleted_at
    assert_equal @deleted_report.name, created.name
  ensure
    cleanup_created_file(created) if defined?(created) && created&.persisted?
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
    assert_equal({ "error" => "実ファイルが見つからないファイルが含まれています" }, response.parsed_body)
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
    assert_equal({ "error" => "ZIPファイルを送信できませんでした" }, response.parsed_body)
    assert captured_result
    assert_not File.exist?(captured_result.zip_path)
  ensure
    Api::V1::DriveItemsController.define_method(:send_zip_file, original_send_zip_file)
  end

  test "対象IDが空の場合にエラーになる" do
    sign_in @user

    post bulk_download_api_v1_drive_items_url, params: { drive_item_ids: [] }

    assert_response :unprocessable_entity
    assert_equal({ "error" => "対象が指定されていません" }, response.parsed_body)
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
