require "test_helper"
require "digest"
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

  test "子孫を持つディレクトリをゴミ箱へ移動すると全子孫が同じ削除バッチになる" do
    sign_in @user
    root = create_directory(name: "trash-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "child", parent: root)
    child_dir = create_directory(name: "child-dir", parent: root)
    grandchild_file = create_named_file(name: "grandchild", extension: "txt", body: "grandchild", parent: child_dir)

    delete api_v1_drive_item_url(root)

    assert_response :ok
    items = [ root, child_file, child_dir, grandchild_file ].map(&:reload)
    assert items.all? { |item| item.deleted_at.present? }
    assert_equal 1, items.map(&:deleted_at).uniq.size
    assert_equal 1, items.map(&:trash_batch_id).uniq.size
    assert items.all? { |item| item.trashed_by_ancestor_id == root.id }
    assert items.all? { |item| item.purged_at.nil? }
  end

  test "ディレクトリ削除前から個別にゴミ箱にあった子孫は削除時刻と削除バッチを維持する" do
    sign_in @user
    root = create_directory(name: "trash-root-keep-child")
    old_deleted_at = 2.days.ago
    old_batch_id = SecureRandom.uuid
    child_file = create_named_file(
      name: "already-trash",
      extension: "txt",
      body: "already-trash",
      parent: root,
      deleted_at: old_deleted_at,
      trash_batch_id: old_batch_id,
      trashed_by_ancestor_id: nil
    )

    delete api_v1_drive_item_url(root)

    assert_response :ok
    assert_equal old_deleted_at.to_i, child_file.reload.deleted_at.to_i
    assert_equal old_batch_id, child_file.trash_batch_id
    assert_nil child_file.trashed_by_ancestor_id
  end

  test "ゴミ箱トップは直接削除されたルートだけを返す" do
    sign_in @user
    root = create_directory(name: "trash-list-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "trash-list-child", parent: root)
    child_dir = create_directory(name: "child-dir", parent: root)
    grandchild_file = create_named_file(name: "grandchild", extension: "txt", body: "trash-list-grandchild", parent: child_dir)

    delete api_v1_drive_item_url(root)
    assert_response :ok

    sign_in @user
    get trash_api_v1_drive_items_url

    assert_response :ok
    ids = response.parsed_body.pluck("id")
    assert_includes ids, root.id
    assert_not_includes ids, child_file.id
    assert_not_includes ids, child_dir.id
    assert_not_includes ids, grandchild_file.id
  end

  test "ゴミ箱内ディレクトリは同じ削除単位の子だけを返す" do
    sign_in @user
    root = create_directory(name: "trash-children-root")
    old_deleted_at = 2.days.ago
    old_child = create_named_file(name: "old-child", extension: "txt", body: "old-trash-child", parent: root, deleted_at: old_deleted_at)
    child_file = create_named_file(name: "child", extension: "txt", body: "trash-child", parent: root)

    delete api_v1_drive_item_url(root)
    assert_response :ok

    sign_in @user
    get trash_api_v1_drive_items_url, params: { parent_id: root.id }

    assert_response :ok
    ids = response.parsed_body.pluck("id")
    assert_includes ids, child_file.id
    assert_not_includes ids, old_child.id
  end

  test "ゴミ箱へ移動したディレクトリ配下のファイルはゴミ箱内同一内容として返す" do
    sign_in @user
    root = create_directory(name: "trash-duplicate-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "folder-trash-content", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok

    sign_in @user
    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-file",
        item_type: "file",
        parent_id: @root.id,
        file: uploaded_file("new-file.txt", "folder-trash-content")
      }
    end

    assert_response :conflict
    assert_equal "trash_content_duplicate", response.parsed_body.dig("error", "code")
    duplicate = response.parsed_body.dig("error", "details", "duplicate")
    assert_equal child_file.id, duplicate.fetch("id")
    assert_equal root.id, duplicate.dig("restore_target", "id")
    assert_equal "directory", duplicate.dig("restore_target", "type")
  end

  test "allow_trash_duplicate でもゴミ箱配下ファイルと同一内容は新規作成しない" do
    sign_in @user
    root = create_directory(name: "trash-upload-anyway-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "upload-anyway-content", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    deleted_at = child_file.reload.deleted_at

    sign_in @user
    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-file",
        item_type: "file",
        parent_id: @root.id,
        allow_trash_duplicate: "true",
        file: uploaded_file("new-file.txt", "upload-anyway-content")
      }
    end

    assert_response :conflict
    assert_equal "trash_content_duplicate", response.parsed_body.dig("error", "code")
    assert_equal deleted_at.to_i, root.reload.deleted_at.to_i
    assert_equal deleted_at.to_i, child_file.reload.deleted_at.to_i
  ensure
    cleanup_created_file(DriveItem.order(:id).last) if response&.created?
  end

  test "復元先フォルダが存在しないゴミ箱内重複ファイルのrestoreはinvalid_parentを返す" do
    sign_in @user
    missing_parent = create_directory(name: "missing-parent", deleted_at: 2.hours.ago, purged_at: 1.hour.ago)
    trashed_file = create_named_file(name: "orphan-trash", extension: "txt", body: "orphan-trash", parent: missing_parent, deleted_at: 30.minutes.ago)

    post restore_api_v1_drive_item_url(trashed_file)

    assert_response :not_found
    assert_equal "invalid_parent", response.parsed_body.dig("error", "code")
    assert_equal "復元先フォルダが見つかりません", response.parsed_body.dig("error", "message")
    assert trashed_file.reload.deleted_at.present?
    assert_nil trashed_file.purged_at
  end

  test "復元先フォルダが存在しないゴミ箱重複もallow_trash_duplicateでは新規作成しない" do
    sign_in @user
    missing_parent = create_directory(name: "missing-parent-upload", deleted_at: 2.hours.ago, purged_at: 1.hour.ago)
    trashed_file = create_named_file(name: "orphan-trash", extension: "txt", body: "orphan-upload", parent: missing_parent, deleted_at: 30.minutes.ago)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        allow_trash_duplicate: "true",
        file: uploaded_file("new-orphan.txt", "orphan-upload")
      }
    end

    assert_response :conflict
    assert_equal "trash_content_duplicate", response.parsed_body.dig("error", "code")
    assert trashed_file.reload.deleted_at.present?
    assert_nil trashed_file.purged_at
  ensure
    cleanup_created_file(created) if defined?(created) && created&.persisted?
  end

  test "replace_trashed_drive_item_idは旧ファイルを完全削除状態にして新規アップロードする" do
    sign_in @user
    missing_parent = create_directory(name: "missing-parent-replace", deleted_at: 2.hours.ago, purged_at: 1.hour.ago)
    trashed_file = create_named_file(name: "orphan-trash", extension: "txt", body: "orphan-replace", parent: missing_parent, deleted_at: 30.minutes.ago)

    assert_difference "DriveItem.count", 1 do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        replace_trashed_drive_item_id: trashed_file.id,
        file: uploaded_file("new-orphan.txt", "orphan-replace")
      }
    end

    assert_response :created
    created = DriveItem.order(:id).last
    assert_nil created.deleted_at
    assert_nil created.purged_at
    assert trashed_file.reload.purged_at.present?
    assert DriveItem.exists?(trashed_file.id)
  ensure
    cleanup_created_file(created) if defined?(created) && created&.persisted?
  end

  test "replace対象が他組織の場合は404で新規作成しない" do
    sign_in @user
    other_trashed = create_named_file(
      name: "other-trash",
      extension: "txt",
      body: "other-replace",
      organization: organizations(:two),
      owner_user: users(:two),
      deleted_at: 30.minutes.ago
    )

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        replace_trashed_drive_item_id: other_trashed.id,
        file: uploaded_file("new-orphan.txt", "other-replace")
      }
    end

    assert_response :not_found
    assert_nil other_trashed.reload.purged_at
  end

  test "replace対象が通常状態ならpurgeせず409を返す" do
    sign_in @user
    active_file = create_named_file(name: "active-replace", extension: "txt", body: "active-replace", parent: @root)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        replace_trashed_drive_item_id: active_file.id,
        file: uploaded_file("new-orphan.txt", "active-replace")
      }
    end

    assert_response :conflict
    assert_equal "replace_target_not_trashed", response.parsed_body.dig("error", "code")
    assert_nil active_file.reload.purged_at
  end

  test "replace対象が完全削除済みなら新規作成しない" do
    sign_in @user
    purged_file = create_named_file(name: "purged-replace", extension: "txt", body: "purged-replace", parent: @root, deleted_at: 1.hour.ago, purged_at: 30.minutes.ago)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        replace_trashed_drive_item_id: purged_file.id,
        file: uploaded_file("new-orphan.txt", "purged-replace")
      }
    end

    assert_response :conflict
    assert_equal "replace_target_already_purged", response.parsed_body.dig("error", "code")
  end

  test "replace対象とアップロード内容が異なる場合はpurgeせず409を返す" do
    sign_in @user
    trashed_file = create_named_file(name: "mismatch-replace", extension: "txt", body: "old-body", parent: @root, deleted_at: 1.hour.ago)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        replace_trashed_drive_item_id: trashed_file.id,
        file: uploaded_file("new-orphan.txt", "new-body")
      }
    end

    assert_response :conflict
    assert_equal "replace_target_mismatch", response.parsed_body.dig("error", "code")
    assert_nil trashed_file.reload.purged_at
  end

  test "replace指定でも新規保存先の同名重複は回避しない" do
    sign_in @user
    trashed_file = create_named_file(name: "replace-name-old", extension: "txt", body: "replace-name", parent: @root, deleted_at: 1.hour.ago)
    create_named_file(name: "new-orphan", extension: "txt", body: "other-content", parent: @root)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "new-orphan",
        item_type: "file",
        parent_id: @root.id,
        replace_trashed_drive_item_id: trashed_file.id,
        file: uploaded_file("new-orphan.txt", "replace-name")
      }
    end

    assert_response :conflict
    assert_equal "duplicate_name", response.parsed_body.dig("error", "code")
    assert_nil trashed_file.reload.purged_at
  end

  test "ゴミ箱内の子ファイルをrestoreすると最上位削除ディレクトリを復元する" do
    sign_in @user
    root = create_directory(name: "restore-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-child", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok

    sign_in @user
    post restore_api_v1_drive_item_url(child_file)

    assert_response :ok
    assert_nil root.reload.deleted_at
    assert_nil child_file.reload.deleted_at
    assert_nil root.trash_batch_id
    assert_nil child_file.trash_batch_id
    assert_equal root.id, response.parsed_body.fetch("id")
  end

  test "子ファイルを持つフォルダを丸ごと復元できる" do
    sign_in @user
    root = create_directory(name: "restore-whole-folder")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-whole-child", parent: root)
    child_dir = create_directory(name: "child-dir", parent: root)
    grandchild_file = create_named_file(name: "grandchild", extension: "txt", body: "restore-whole-grandchild", parent: child_dir)
    delete api_v1_drive_item_url(root)
    assert_response :ok

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :ok
    assert [ root, child_file, child_dir, grandchild_file ].all? { |item| item.reload.deleted_at.nil? }
    assert [ root, child_file, child_dir, grandchild_file ].all? { |item| item.reload.purged_at.nil? }
  end

  test "フォルダ復元は復元対象サブツリー内の同一ハッシュを重複判定しない" do
    sign_in @user
    root = create_directory(name: "restore-same-hash-subtree")
    child_file = create_named_file(name: "child-a", extension: "txt", body: "same-restore-hash", parent: root)
    child_dir = create_directory(name: "child-dir", parent: root)
    grandchild_file = create_named_file(name: "child-b", extension: "txt", body: "same-restore-hash", parent: child_dir)
    delete api_v1_drive_item_url(root)
    assert_response :ok

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :ok
    assert_nil root.reload.deleted_at
    assert_nil child_file.reload.deleted_at
    assert_nil grandchild_file.reload.deleted_at
  end

  test "フォルダ復元はゴミ箱内の同名要素を重複判定しない" do
    sign_in @user
    root = create_directory(name: "restore-ignore-trash-name")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-trash-name", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    create_named_file(name: "child", extension: "txt", body: "other-trash-name", parent: root, deleted_at: 30.minutes.ago)

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :ok
    assert_nil root.reload.deleted_at
    assert_nil child_file.reload.deleted_at
  end

  test "フォルダ復元は完全削除済み要素を重複判定しない" do
    sign_in @user
    root = create_directory(name: "restore-ignore-purged-name")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-purged-name", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    create_named_file(name: "child", extension: "txt", body: "other-purged-name", parent: root, deleted_at: 1.hour.ago, purged_at: 30.minutes.ago)

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :ok
    assert_nil root.reload.deleted_at
    assert_nil child_file.reload.deleted_at
  end

  test "フォルダ復元は復元先の有効な同名要素と競合する" do
    sign_in @user
    root = create_directory(name: "restore-active-name-conflict")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-active-name", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    existing = create_named_file(name: "child", extension: "txt", body: "active-name-conflict", parent: root)

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :conflict
    assert_equal "restore_conflict", response.parsed_body.dig("error", "code")
    conflict = response.parsed_body.dig("error", "details", "conflicts").first
    assert_equal "name_conflict", conflict.fetch("conflict_type")
    assert_equal "restore-active-name-conflict/child.txt", conflict.fetch("relative_path")
    assert_equal existing.id, conflict.dig("existing_item", "id")
    assert root.reload.deleted_at.present?
    assert child_file.reload.deleted_at.present?
  end

  test "フォルダ復元は復元先の有効な同一ハッシュ要素と競合する" do
    sign_in @user
    root = create_directory(name: "restore-active-content-conflict")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-active-content", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    existing = create_named_file(name: "existing-content", extension: "txt", body: "restore-active-content", parent: @root)

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :conflict
    assert_equal "restore_conflict", response.parsed_body.dig("error", "code")
    conflict = response.parsed_body.dig("error", "details", "conflicts").first
    assert_equal "active_content_duplicate", conflict.fetch("conflict_type")
    assert_equal "restore-active-content-conflict/child.txt", conflict.fetch("relative_path")
    assert_equal existing.id, conflict.dig("existing_item", "id")
    assert root.reload.deleted_at.present?
    assert child_file.reload.deleted_at.present?
  end

  test "フォルダ復元で子孫が競合した場合は全要素がゴミ箱状態のまま残る" do
    sign_in @user
    root = create_directory(name: "restore-atomic-conflict")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-atomic-child", parent: root)
    child_dir = create_directory(name: "child-dir", parent: root)
    grandchild_file = create_named_file(name: "grandchild", extension: "txt", body: "restore-atomic-grandchild", parent: child_dir)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    create_named_file(name: "grandchild", extension: "txt", body: "active-grandchild-conflict", parent: child_dir)

    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :conflict
    assert [ root, child_file, child_dir, grandchild_file ].all? { |item| item.reload.deleted_at.present? }
    assert [ root, child_file, child_dir, grandchild_file ].all? { |item| item.reload.purged_at.nil? }
  end

  test "ディレクトリ復元は同じ削除バッチの子孫だけ復元する" do
    sign_in @user
    root = create_directory(name: "restore-batch-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "restore-batch-child", parent: root)
    already_deleted = create_named_file(name: "already-deleted", extension: "txt", body: "restore-batch-old", parent: root, deleted_at: 2.days.ago)

    delete api_v1_drive_item_url(root)
    assert_response :ok
    sign_in @user
    post restore_api_v1_drive_item_url(root)

    assert_response :ok
    assert_nil root.reload.deleted_at
    assert_nil child_file.reload.deleted_at
    assert already_deleted.reload.deleted_at.present?
  end

  test "restore_preview は同名競合と自動リネーム後の名前を返す" do
    sign_in @user
    trashed_file = create_named_file(name: "test1", extension: "txt", body: "trash", parent: @root, deleted_at: 1.hour.ago)
    create_named_file(name: "test1", extension: "txt", body: "active1", parent: @root)
    create_named_file(name: "test1 (1)", extension: "txt", body: "active2", parent: @root)

    post restore_preview_api_v1_drive_item_url(trashed_file)

    assert_response :ok
    item = response.parsed_body.fetch("items").first
    assert_equal "name_conflict", item.fetch("conflict_type")
    assert_equal "test1.txt", item.dig("before", "name")
    assert_equal "test1.txt", item.dig("after", "name")
    assert_equal "restore", item.dig("after", "resolution")
    assert_equal 1, response.parsed_body.dig("summary", "conflict_count")
    assert_equal 0, response.parsed_body.dig("summary", "rename_count")
  end

  test "restore_preview は親フォルダ欠損を検出しルート復元を推奨する" do
    sign_in @user
    missing_parent = create_directory(name: "missing-preview-parent", deleted_at: 2.hours.ago, purged_at: 1.hour.ago)
    trashed_file = create_named_file(name: "orphan-preview", extension: "txt", body: "orphan-preview", parent: missing_parent, deleted_at: 1.hour.ago)

    post restore_preview_api_v1_drive_item_url(trashed_file)

    assert_response :ok
    item = response.parsed_body.fetch("items").first
    assert_equal "missing_parent", item.fetch("conflict_type")
    assert_equal false, item.fetch("parent_exists")
    assert_equal "restore_to_root", item.fetch("recommended_resolution")
    assert_equal "/共有ドライブ", item.dig("after", "parent_path")
    assert_match "元の復元先フォルダ", item.dig("before", "reason")
  end

  test "restore_preview は競合なしの単一ファイルで安定した結果を返し状態を変更しない" do
    sign_in @user
    trashed_file = create_named_file(name: "simple-preview", extension: "txt", body: "simple-preview", parent: @root, deleted_at: 1.hour.ago)
    before_attributes = trashed_file.reload.attributes.slice("deleted_at", "parent_id", "updated_at")

    post restore_preview_api_v1_drive_item_url(trashed_file)
    assert_response :ok
    first = response.parsed_body

    trashed_file.reload
    assert_equal before_attributes, trashed_file.attributes.slice("deleted_at", "parent_id", "updated_at")

    sign_in @user
    post restore_preview_api_v1_drive_item_url(trashed_file)
    assert_response :ok
    second = response.parsed_body

    assert_equal first, second
    assert_equal 0, first.dig("summary", "conflict_count")
    assert_equal 1, first.dig("summary", "restorable_count")
    assert_equal "restore", first.dig("items", 0, "after", "resolution")
    assert first.fetch("confirmation_token").present?
  end

  test "restore は競合なしpreview tokenで単一ファイルを復元する" do
    sign_in @user
    trashed_file = create_named_file(name: "simple-restore", extension: "txt", body: "simple-restore", parent: @root, deleted_at: 1.hour.ago)

    post restore_preview_api_v1_drive_item_url(trashed_file)
    assert_response :ok
    confirmation_token = response.parsed_body.fetch("confirmation_token")
    assert confirmation_token.present?

    sign_in @user
    post restore_api_v1_drive_item_url(trashed_file), params: {
      confirmation_token: confirmation_token
    }

    assert_response :ok
    assert_nil trashed_file.reload.deleted_at
    assert_equal @root.id, trashed_file.parent_id
  end

  test "restore はconfirmation tokenと旧形式itemsが同時に送られてもitemsを無視する" do
    sign_in @user
    trashed_file = create_named_file(name: "token-only-restore", extension: "txt", body: "token-only-restore", parent: @root, deleted_at: 1.hour.ago)

    post restore_preview_api_v1_drive_item_url(trashed_file)
    assert_response :ok
    confirmation_token = response.parsed_body.fetch("confirmation_token")

    sign_in @user
    post restore_api_v1_drive_item_url(trashed_file), params: {
      confirmation_token: confirmation_token,
      items: [
        {
          item_id: trashed_file.id,
          resolution: "select_destination",
          destination_parent_id: 0,
          expected_existing_item_id: 0
        }
      ]
    }

    assert_response :ok
    assert_nil trashed_file.reload.deleted_at
    assert_equal @root.id, trashed_file.parent_id
  end

  test "restore はpreview後に無関係なDriveItemを更新しても成功する" do
    sign_in @user
    trashed_file = create_named_file(name: "unrelated-restore", extension: "txt", body: "unrelated-restore", parent: @root, deleted_at: 1.hour.ago)
    unrelated = create_named_file(name: "unrelated-active", extension: "txt", body: "unrelated-active", parent: @root)

    post restore_preview_api_v1_drive_item_url(trashed_file)
    assert_response :ok
    item = response.parsed_body.fetch("items").first
    unrelated.touch

    sign_in @user
    post restore_api_v1_drive_item_url(trashed_file), params: {
      items: [
        {
          item_id: item.fetch("item_id"),
          resolution: item.dig("after", "resolution"),
          destination_parent_id: item.dig("after", "parent_id"),
          expected_name: item.dig("after", "name"),
          expected_existing_item_id: item.fetch("existing_item_id")
        }
      ]
    }

    assert_response :ok
    assert_nil trashed_file.reload.deleted_at
  end

  test "bulk_restore_preview は複数競合を1つのレスポンスに保持する" do
    sign_in @user
    trashed_a = create_named_file(name: "conflict-a", extension: "txt", body: "a", parent: @root, deleted_at: 1.hour.ago)
    trashed_b = create_named_file(name: "conflict-b", extension: "txt", body: "b", parent: @root, deleted_at: 1.hour.ago)
    create_named_file(name: "conflict-a", extension: "txt", body: "active-a", parent: @root)
    create_named_file(name: "conflict-b", extension: "txt", body: "active-b", parent: @root)

    post bulk_restore_preview_api_v1_drive_items_url, params: { drive_item_ids: [ trashed_a.id, trashed_b.id ] }

    assert_response :ok
    assert_equal [ trashed_a.id, trashed_b.id ].sort, response.parsed_body.fetch("items").pluck("item_id").sort
    assert_equal 2, response.parsed_body.dig("summary", "conflict_count")
  end

  test "restore_preview はフォルダ配下の同名競合も再帰的に返す" do
    sign_in @user
    root = create_directory(name: "preview-tree-root")
    child = create_named_file(name: "nested", extension: "txt", body: "nested-trash", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    active_shadow = create_named_file(name: "nested", extension: "txt", body: "nested-active", parent: root)

    sign_in @user
    post restore_preview_api_v1_drive_item_url(root)

    assert_response :ok
    item = response.parsed_body.fetch("items").find { |entry| entry.fetch("item_id") == child.id }
    assert_equal "name_conflict", item.fetch("conflict_type")
    assert_equal active_shadow.id, item.fetch("existing_item_id")
  end

  test "restore_preview は復元対象外の有効な同一ハッシュだけを内容重複として返す" do
    sign_in @user
    root = create_directory(name: "preview-content-root")
    child = create_named_file(name: "nested", extension: "txt", body: "preview-content", parent: root)
    create_named_file(name: "same-in-subtree", extension: "txt", body: "preview-content", parent: root)
    delete api_v1_drive_item_url(root)
    assert_response :ok
    active_duplicate = create_named_file(name: "active-content", extension: "txt", body: "preview-content", parent: @root)

    sign_in @user
    post restore_preview_api_v1_drive_item_url(root)

    assert_response :ok
    item = response.parsed_body.fetch("items").find { |entry| entry.fetch("item_id") == child.id }
    assert_equal "active_content_duplicate", item.fetch("conflict_type")
    assert_equal active_duplicate.id, item.fetch("existing_item_id")
    assert_equal "組織内に同じ内容のファイルがあります", item.dig("before", "reason")
  end

  test "restore with rename resolution restores using previewed name" do
    sign_in @user
    trashed_file = create_named_file(name: "restore-rename", extension: "txt", body: "trash", parent: @root, deleted_at: 1.hour.ago)
    existing = create_named_file(name: "restore-rename", extension: "txt", body: "active", parent: @root)

    post restore_preview_api_v1_drive_item_url(trashed_file), params: {
      items: [
        {
          item_id: trashed_file.id,
          resolution: "rename",
          expected_name: "restore-rename (1).txt",
          expected_existing_item_id: existing.id
        }
      ]
    }
    assert_response :ok
    confirmation_token = response.parsed_body.fetch("confirmation_token")

    sign_in @user
    post restore_api_v1_drive_item_url(trashed_file), params: { confirmation_token: confirmation_token }

    assert_response :ok
    assert_nil trashed_file.reload.deleted_at
    assert_equal "restore-rename (1)", trashed_file.name
  end

  test "restore with trash_existing moves only the previewed existing item to trash" do
    sign_in @user
    trashed_file = create_named_file(name: "restore-purge-existing", extension: "txt", body: "trash", parent: @root, deleted_at: 1.hour.ago)
    existing = create_named_file(name: "restore-purge-existing", extension: "txt", body: "active", parent: @root)
    other = create_named_file(name: "restore-purge-other", extension: "txt", body: "other", parent: @root)

    post restore_api_v1_drive_item_url(trashed_file), params: {
      items: [
        {
          item_id: trashed_file.id,
          resolution: "trash_existing",
          expected_name: "restore-purge-existing.txt",
          expected_existing_item_id: existing.id
        }
      ]
    }

    assert_response :ok
    assert_nil trashed_file.reload.deleted_at
    assert existing.reload.deleted_at.present?
    assert_nil existing.reload.purged_at
    assert_nil other.reload.purged_at
  end

  test "restore はプレビュー後に状態が変わった場合 restore_state_changed を返す" do
    sign_in @user
    trashed_file = create_named_file(name: "restore-stale", extension: "txt", body: "trash", parent: @root, deleted_at: 1.hour.ago)

    post restore_preview_api_v1_drive_item_url(trashed_file)
    assert_response :ok
    confirmation_token = response.parsed_body.fetch("confirmation_token")
    create_named_file(name: "restore-stale", extension: "txt", body: "new-active", parent: @root)

    sign_in @user
    post restore_api_v1_drive_item_url(trashed_file), params: {
      confirmation_token: confirmation_token
    }

    assert_response :conflict
    assert_equal "restore_state_changed", response.parsed_body.dig("error", "code")
    assert trashed_file.reload.deleted_at.present?
    assert_equal "restore-stale.txt", response.parsed_body.dig("error", "details", "items", 0, "after", "name")
  end

  test "restore with select_destination requires an explicit active destination" do
    sign_in @user
    missing_parent = create_directory(name: "restore-missing-parent", parent: @root)
    trashed_file = create_named_file(name: "restore-select-destination", extension: "txt", body: "trash", parent: missing_parent, deleted_at: 1.hour.ago)
    missing_parent.update!(deleted_at: 1.hour.ago, purged_at: Time.current)

    post restore_api_v1_drive_item_url(trashed_file), params: {
      items: [
        {
          item_id: trashed_file.id,
          resolution: "select_destination",
          expected_name: "restore-select-destination.txt",
          expected_existing_item_id: nil
        }
      ]
    }

    assert_response :conflict
    assert_equal "restore_state_changed", response.parsed_body.dig("error", "code")
    assert trashed_file.reload.deleted_at.present?
    assert_equal missing_parent.id, trashed_file.parent_id
  end

  test "active なアイテムは restore できない" do
    sign_in @user

    post restore_api_v1_drive_item_url(@root)

    assert_response :not_found
  end

  test "削除済みファイルを purge できる" do
    sign_in @user
    deleted_file = create_named_file(name: "purge-target", extension: "txt", body: "purge", parent: @root, deleted_at: Time.current)
    storage_path = deleted_file.absolute_storage_path

    assert_no_difference "DriveItem.count" do
      assert_difference "AuditEvent.where(action: 'drive_item.purge').count", 1 do
        delete purge_api_v1_drive_item_url(deleted_file)
      end
    end

    assert_response :ok
    assert_equal "ファイルを完全削除しました", response.parsed_body.fetch("message")
    assert deleted_file.reload.purged_at.present?
    assert_equal @user, deleted_file.purged_by_user
    assert_not File.exist?(storage_path)
  end

  test "ゴミ箱内の多階層フォルダを purge して通常APIから除外する" do
    sign_in @user
    root = DriveItem.create!(organization: @organization, owner_user: @user, name: "purge-root", item_type: "directory", deleted_at: Time.current)
    child = DriveItem.create!(organization: @organization, owner_user: @user, parent: root, name: "purge-child", item_type: "directory")
    file = create_named_file(name: "nested", extension: "txt", body: "nested", parent: child)
    storage_path = file.absolute_storage_path

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_drive_item_url(root)
    end

    assert_response :ok
    assert_equal 1, [ root, child, file ].map { |item| item.reload.purged_at }.uniq.size
    assert_not File.exist?(storage_path)
    assert [ root, child, file ].all? { |item| item.reload.trash_batch_id.nil? }

    sign_in @user
    get api_v1_drive_item_url(root)
    assert_response :not_found
    sign_in @user
    get trash_api_v1_drive_items_url
    assert_response :ok
    assert_not_includes response.parsed_body.pluck("id"), root.id
  end

  test "active なアイテムは purge できない" do
    sign_in @user

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_drive_item_url(@file)
    end

    assert_response :not_found
    assert DriveItem.exists?(@file.id)
  end

  test "他組織の削除済みアイテムは purge できない" do
    sign_in @user
    other_deleted_file = create_named_file(
      name: "other-purge-target",
      extension: "txt",
      body: "other-purge",
      organization: organizations(:two),
      owner_user: users(:two),
      deleted_at: Time.current
    )

    assert_no_difference "DriveItem.count" do
      delete purge_api_v1_drive_item_url(other_deleted_file)
    end

    assert_response :not_found
    assert DriveItem.exists?(other_deleted_file.id)
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
    assert_equal "#{@file.name}.#{@file.extension}", response.parsed_body.dig("error", "details", "conflicting_name")
    assert response.parsed_body.dig("error", "request_id").present?
  end

  test "同名アップロードは利用可能な最小連番を候補として返す" do
    sign_in @user
    create_named_file(name: "ファイル", extension: "txt", body: "first", parent: @root)
    create_named_file(name: "ファイル（1）", extension: "txt", body: "second", parent: @root)
    create_named_file(name: "ファイル（3）", extension: "txt", body: "third", parent: @root)

    post api_v1_drive_items_url, params: {
      name: "ファイル",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("ファイル.txt", "different")
    }

    assert_response :conflict
    assert_equal "duplicate_name", response.parsed_body.dig("error", "code")
    assert_equal "name", response.parsed_body.dig("error", "details", "duplicate_kind")
    assert_equal "ファイル（2）", response.parsed_body.dig("error", "details", "suggested_name")
    assert_equal "ファイル（2）.txt", response.parsed_body.dig("error", "details", "suggested_filename")
  end

  test "同一内容アップロードは組織内の別フォルダでも重複内容として返す" do
    sign_in @user
    other_folder = create_directory(name: "other-folder")
    create_named_file(name: "別名", extension: "txt", body: "same-content", parent: other_folder)

    post api_v1_drive_items_url, params: {
      name: "ファイル",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("ファイル.txt", "same-content")
    }

    assert_response :conflict
    assert_equal "active_content_duplicate", response.parsed_body.dig("error", "code")
    assert_equal "same_content", response.parsed_body.dig("error", "details", "duplicate_kind")
    assert_equal "同じ内容のファイルが、この組織内にすでに存在します。", response.parsed_body.dig("error", "message")
    duplicate_files = response.parsed_body.dig("error", "details", "duplicate_files")
    assert_equal 1, duplicate_files.size
    assert_equal "別名.txt", duplicate_files.first.fetch("name")
    assert_equal other_folder.name, duplicate_files.first.fetch("parent_name")
    assert_equal @user.safe_display_name, duplicate_files.first.fetch("owner_display_name")
    assert_equal false, duplicate_files.first.fetch("deleted")
  end

  test "allow_duplicate_content が true の場合は同一内容でも新規作成できる" do
    sign_in @user
    create_named_file(name: "既存", extension: "txt", body: "same-content", parent: @root)

    assert_difference "DriveItem.count", 1 do
      post api_v1_drive_items_url, params: {
        name: "新規",
        item_type: "file",
        parent_id: @root.id,
        allow_duplicate_content: "true",
        file: uploaded_file("新規.txt", "same-content")
      }
    end

    assert_response :created
    assert_equal "新規", response.parsed_body.fetch("name")
  end

  test "allow_duplicate_content が false の場合は同一内容を拒否する" do
    sign_in @user
    create_named_file(name: "既存", extension: "txt", body: "same-content", parent: @root)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "新規",
        item_type: "file",
        parent_id: @root.id,
        allow_duplicate_content: "false",
        file: uploaded_file("新規.txt", "same-content")
      }
    end

    assert_response :conflict
    assert_equal "active_content_duplicate", response.parsed_body.dig("error", "code")
  end

  test "同一内容がごみ箱だけにある場合は専用409を返す" do
    sign_in @user
    trashed = create_named_file(name: "削除済み", extension: "txt", body: "trash-content", parent: @root, deleted_at: Time.current)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "新規",
        item_type: "file",
        parent_id: @root.id,
        file: uploaded_file("新規.txt", "trash-content")
      }
    end

    assert_response :conflict
    assert_equal "trash_content_duplicate", response.parsed_body.dig("error", "code")
    assert_equal trashed.id, response.parsed_body.dig("error", "details", "duplicate", "id")
  end

  test "同一内容がごみ箱だけにあり allow_trash_duplicate が true でも新規作成しない" do
    sign_in @user
    create_named_file(name: "ファイルA", extension: "txt", body: "trash-content", parent: @root, deleted_at: Time.current)

    assert_no_difference "DriveItem.count" do
      post api_v1_drive_items_url, params: {
        name: "ファイルB",
        item_type: "file",
        parent_id: @root.id,
        allow_trash_duplicate: "true",
        file: uploaded_file("ファイルB.txt", "trash-content")
      }
    end

    assert_response :conflict
    assert_equal "trash_content_duplicate", response.parsed_body.dig("error", "code")
  ensure
    cleanup_created_file(created) if defined?(created) && created&.persisted?
  end

  test "削除済み祖先を持つ不整合子ファイルは通常領域重複ではなくゴミ箱重複として扱う" do
    sign_in @user
    root = create_directory(name: "inconsistent-root")
    child_file = create_named_file(name: "child", extension: "txt", body: "inconsistent-content", parent: root)
    root.update!(deleted_at: Time.current)

    post api_v1_drive_items_url, params: {
      name: "new-file",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("new-file.txt", "inconsistent-content")
    }

    assert_response :conflict
    assert_equal "trash_content_duplicate", response.parsed_body.dig("error", "code")
    assert_equal child_file.id, response.parsed_body.dig("error", "details", "duplicate", "id")
    assert_equal root.id, response.parsed_body.dig("error", "details", "duplicate", "restore_target", "id")
  end

  test "他組織の同一内容ファイルは重複内容として通知しない" do
    sign_in @user
    create_named_file(
      name: "他組織",
      extension: "txt",
      body: "tenant-content",
      organization: organizations(:two),
      owner_user: users(:two)
    )

    post api_v1_drive_items_url, params: {
      name: "新規",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("新規.txt", "tenant-content")
    }

    assert_response :created
    assert_equal "新規", response.parsed_body.fetch("name")
  end

  test "同一hashは同名重複より先に返す" do
    sign_in @user
    create_named_file(name: "別名", extension: "txt", body: "same-content", parent: create_directory(name: "別フォルダ"))
    create_named_file(name: "ファイル", extension: "txt", body: "other-content", parent: @root)

    post api_v1_drive_items_url, params: {
      name: "ファイル",
      item_type: "file",
      parent_id: @root.id,
      file: uploaded_file("ファイル.txt", "same-content")
    }

    assert_response :conflict
    assert_equal "active_content_duplicate", response.parsed_body.dig("error", "code")
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

  def create_directory(name:, parent: nil, deleted_at: nil, purged_at: nil)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: parent,
      name: name,
      item_type: "directory",
      deleted_at: deleted_at,
      purged_at: purged_at
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

  def create_named_file(name:, extension:, body:, parent: nil, deleted_at: nil, purged_at: nil, trash_batch_id: nil, trashed_by_ancestor_id: nil, organization: @organization, owner_user: @user)
    storage_key = "#{SecureRandom.uuid}.#{extension}"
    write_storage_file(storage_key, body)

    DriveItem.create!(
      organization: organization,
      owner_user: owner_user,
      parent: parent,
      name: name,
      item_type: "file",
      extension: extension,
      blob_path: storage_key,
      storage_key: storage_key,
      file_hash: Digest::SHA256.hexdigest(body),
      file_size: body.bytesize,
      content_type: "text/plain",
      deleted_at: deleted_at,
      purged_at: purged_at,
      trash_batch_id: trash_batch_id,
      trashed_by_ancestor_id: trashed_by_ancestor_id
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
