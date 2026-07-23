require "test_helper"
require "digest"
require "fileutils"

class DriveItems::PurgeServiceTest < ActiveSupport::TestCase
  setup do
    @organization = organizations(:one)
    @user = users(:one)
    @storage_paths = []
  end

  teardown do
    @storage_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "空フォルダを完全削除済みにする" do
    directory = create_directory(deleted_at: Time.current)

    result = purge(directory)

    assert result.success?
    assert_equal "フォルダを完全削除しました", result.message
    assert directory.reload.purged_at.present?
    assert_equal @user, directory.purged_by_user
    assert_not_includes DriveItem.active, directory
    assert_not_includes DriveItem.trashed, directory
  end

  test "親だけがゴミ箱状態でも多階層の子孫を同じ時刻で完全削除済みにする" do
    root = create_directory(deleted_at: Time.current)
    file_a = create_file(parent: root, body: "a")
    directory_a = create_directory(parent: root)
    file_b = create_file(parent: directory_a, body: "b")
    directory_b = create_directory(parent: directory_a)
    file_c = create_file(parent: directory_b, body: "c")
    items = [ root, file_a, directory_a, file_b, directory_b, file_c ]

    result = purge(root)

    assert result.success?
    assert_equal 1, items.map { |item| item.reload.purged_at }.uniq.size
    assert items.all? { |item| item.deleted_at.present? }
    assert items.all? { |item| DriveItem.exists?(item.id) }
    assert [ file_a, file_b, file_c ].none? { |item| File.exist?(storage_path_for(item)) }
  end

  test "ファイル単体の完全削除仕様を維持する" do
    file = create_file(body: "single", deleted_at: Time.current)
    path = storage_path_for(file)

    result = purge(file)

    assert result.success?
    assert_equal "ファイルを完全削除しました", result.message
    assert file.reload.purged_at.present?
    assert_nil file.storage_key
    assert_nil file.blob_path
    assert_not File.exist?(path)
  end

  test "DB更新途中の例外は全件をロールバックして実ファイルを残す" do
    root = create_directory(deleted_at: Time.current)
    first = create_file(parent: root, body: "first")
    second = create_file(parent: root, body: "second")
    second.define_singleton_method(:update!) { |**| raise ActiveRecord::RecordInvalid, self }
    service = DriveItems::PurgeService.new(drive_item: root, actor_user: @user)
    service.define_singleton_method(:collect_items) { [ root, first, second ] }

    result = service.call

    assert_not result.success?
    assert_nil root.reload.purged_at
    assert_nil first.reload.purged_at
    assert_nil second.reload.purged_at
    assert File.exist?(storage_path_for(first))
    assert File.exist?(storage_path_for(second))
  end

  test "実ファイル削除はDBコミット後に実行する" do
    file = create_file(body: "after commit", deleted_at: Time.current)
    purged_when_deleted = nil
    remover = lambda do |path|
      purged_when_deleted = file.reload.purged_at.present?
      File.unlink(path)
    end

    result = with_singleton_method(FileUtils, :rm_f, remover) { purge(file) }

    assert result.success?
    assert_equal true, purged_when_deleted
  end

  test "実ファイル削除失敗は成功扱いにして必要情報をログへ記録する" do
    file = create_file(body: "failure", deleted_at: Time.current)
    original_key = file.storage_key
    original_blob_path = file.blob_path
    logger = CapturingLogger.new

    result = with_singleton_method(Rails, :logger, -> { logger }) do
      with_singleton_method(FileUtils, :rm_f, ->(*) { raise Errno::EACCES, "denied" }) { purge(file) }
    end

    assert result.success?
    assert file.reload.purged_at.present?
    log = logger.errors.one
    assert_includes log, "root_drive_item_id=#{file.id}"
    assert_includes log, "drive_item_id=#{file.id}"
    assert_includes log, "storage_key=#{original_key}"
    assert_includes log, "blob_path=#{original_blob_path}"
    assert_includes log, "error_class=Errno::EACCES"
    assert_includes log, "error_message=Permission denied - denied"
    assert_includes log, "backtrace="
  end

  test "同一ストレージ実体の削除は重複実行しない" do
    root = create_directory(deleted_at: Time.current)
    first = create_file(parent: root, body: "shared")
    second = create_file(parent: root, body: "other")
    second.update_columns(storage_key: first.storage_key, blob_path: first.blob_path)
    calls = 0
    remover = lambda do |path|
      calls += 1
      File.unlink(path) if File.exist?(path)
    end

    result = with_singleton_method(FileUtils, :rm_f, remover) { purge(root) }

    assert result.success?
    assert_equal 1, calls
  end

  test "削除対象外のDriveItemが参照する同一実体は削除しない" do
    root = create_directory(deleted_at: Time.current)
    target = create_file(parent: root, body: "shared")
    reference = create_file(body: "other")
    reference.update_columns(storage_key: target.storage_key, blob_path: target.blob_path)
    path = storage_path_for(target)

    result = purge(root)

    assert result.success?
    assert File.exist?(path)
    assert_nil reference.reload.purged_at
  end

  test "他組織のDriveItemが参照する同一実体は削除しない" do
    root = create_directory(deleted_at: Time.current)
    target = create_file(parent: root, body: "cross organization")
    other = drive_items(:two)
    other.update_columns(storage_key: target.storage_key, blob_path: target.blob_path)
    path = storage_path_for(target)

    result = purge(root)

    assert result.success?
    assert File.exist?(path)
    assert_nil other.reload.purged_at
  end

  test "他組織の子要素を検出した場合は全体を中止する" do
    root = create_directory(deleted_at: Time.current)
    other = drive_items(:two)
    other.update_columns(parent_id: root.id)

    result = purge(root)

    assert_not result.success?
    assert_nil root.reload.purged_at
    assert_nil other.reload.purged_at
  end

  test "ゴミ箱外のフォルダは完全削除できない" do
    root = create_directory
    child = create_file(parent: root, body: "active")

    result = purge(root)

    assert_not result.success?
    assert_equal "先にゴミ箱へ移動してください", result.message
    assert_nil root.reload.purged_at
    assert_nil child.reload.purged_at
    assert File.exist?(storage_path_for(child))
  end

  private

  class CapturingLogger
    attr_reader :errors

    def initialize
      @errors = []
    end

    def error(message)
      @errors << message
    end
  end

  def purge(item)
    DriveItems::PurgeService.new(drive_item: item, actor_user: @user).call
  end

  def create_directory(parent: nil, deleted_at: nil)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: parent,
      name: "purge-dir-#{SecureRandom.hex(4)}",
      item_type: "directory",
      deleted_at: deleted_at
    )
  end

  def create_file(parent: nil, body:, deleted_at: nil)
    storage_key = "#{SecureRandom.uuid}.txt"
    path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body)
    @storage_paths << path

    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: parent,
      name: "purge-#{SecureRandom.hex(4)}",
      item_type: "file",
      extension: "txt",
      storage_key: storage_key,
      content_type: "text/plain",
      file_hash: Digest::SHA256.hexdigest(body),
      file_size: body.bytesize,
      deleted_at: deleted_at
    )
  end

  def storage_path_for(item)
    DriveItem.storage_root.join(item.blob_path)
  end

  def with_singleton_method(receiver, method_name, implementation)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name, &implementation)
    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end
end
