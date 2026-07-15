require "test_helper"
require "tempfile"

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
    @tempfiles = []
  end

  teardown do
    @tempfiles.each do |tempfile|
      tempfile.close
      tempfile.unlink
    end
  end

  test "should get index" do
    get drive_items_url
    assert_response :unauthorized
  end

  test "should get show" do
    get drive_item_url(drive_items(:one))
    assert_response :unauthorized
  end

  test "他組織のアイテムへアクセスできない" do
    sign_in @user

    get drive_item_url(@other_item)

    assert_response :not_found
  end

  test "削除済みアイテムは show できない" do
    sign_in @user

    get drive_item_url(@deleted_folder)

    assert_response :not_found
  end

  test "削除済みアイテムは update できない" do
    sign_in @user

    patch drive_item_url(@deleted_folder), params: { name: "restored_name" }

    assert_response :not_found
    assert_equal "deleted_folder", @deleted_folder.reload.name
  end

  test "削除済みアイテムは destroy できない" do
    sign_in @user

    delete drive_item_url(@deleted_folder)

    assert_response :not_found
    assert @deleted_folder.reload.deleted_at.present?
  end

  test "削除済みアイテムを restore できる" do
    sign_in @user

    post restore_drive_item_url(@deleted_folder)

    assert_response :ok
    assert_nil @deleted_folder.reload.deleted_at
  end

  test "active なアイテムは restore できない" do
    sign_in @user

    post restore_drive_item_url(@root)

    assert_response :not_found
  end

  test "update でルート直下へ移動できる" do
    sign_in @user

    patch drive_item_url(@child_folder), params: { parent_id: "" }

    assert_response :ok
    assert_nil @child_folder.reload.parent_id
  end

  test "ファイルを親に指定できない" do
    sign_in @user

    patch drive_item_url(@child_folder), params: { parent_id: @file.id }

    assert_response :unprocessable_entity
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "自分自身を親に指定できない" do
    sign_in @user

    patch drive_item_url(@child_folder), params: { parent_id: @child_folder.id }

    assert_response :unprocessable_entity
    assert_equal @root.id, @child_folder.reload.parent_id
  end

  test "子孫フォルダへ移動できない" do
    sign_in @user

    patch drive_item_url(@child_folder), params: { parent_id: @grandchild_folder.id }

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

    post bulk_move_drive_items_url, params: {
      drive_item_ids: [ movable.id, ancestor.id ],
      parent_id: descendant.id
    }

    assert_response :unprocessable_entity
    assert_equal @root.id, movable.reload.parent_id
    assert_equal @root.id, ancestor.reload.parent_id
  end

  test "DB保存失敗時にアップロード済みファイルが削除される" do
    sign_in @user
    storage_dir = Rails.root.join("storage", "drive_items")
    FileUtils.mkdir_p(storage_dir)
    before_files = Dir.children(storage_dir)
    original_save = DriveItem.instance_method(:save)

    DriveItem.define_method(:save) do |*args, **kwargs|
      false
    end

    post drive_items_url, params: {
      name: "orphan",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("orphan.txt", "orphan")
    }

    assert_response :unprocessable_entity
    assert_equal before_files.sort, Dir.children(storage_dir).sort
  ensure
    DriveItem.define_method(:save, original_save)
  end

  test "ゴミ箱内に同名アイテムがあっても新規作成できる" do
    sign_in @user

    assert_difference "DriveItem.count", 1 do
      post drive_items_url, params: {
        name: @deleted_report.name,
        item_type: "file",
        parent_id: @root.id,
        file: uploaded_file("#{@deleted_report.name}.txt", "new")
      }
    end

    assert_response :created
    created = DriveItem.order(:id).last
    assert_nil created.deleted_at
    assert_equal @deleted_report.name, created.name
  ensure
    cleanup_created_file(created) if defined?(created) && created&.persisted?
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
end
