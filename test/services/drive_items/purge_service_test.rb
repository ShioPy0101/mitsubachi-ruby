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
    @storage_paths.each do |path|
      FileUtils.rm_f(path)
      Dir.glob("#{path}.purging-*").each { |temporary_path| FileUtils.rm_f(temporary_path) }
    end
  end

  test "正常時はDBレコードと一時ファイルを削除する" do
    drive_item = create_deleted_file(body: "purge")
    storage_path = drive_item.absolute_storage_path

    result = DriveItems::PurgeService.new(drive_item: drive_item).call

    assert result.success?
    assert_equal "ファイルを完全削除しました", result.message
    assert_not DriveItem.exists?(drive_item.id)
    assert_not File.exist?(storage_path)
    assert_empty temporary_files_for(storage_path)
  end

  test "destroy! が失敗した場合は一時ファイルを元パスへ復元する" do
    drive_item = create_deleted_file(body: "destroy failure")
    storage_path = drive_item.absolute_storage_path
    drive_item.define_singleton_method(:destroy!) do
      raise ActiveRecord::RecordInvalid, self
    end

    result = DriveItems::PurgeService.new(drive_item: drive_item).call

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert DriveItem.exists?(drive_item.id)
    assert_equal "destroy failure", File.binread(storage_path)
    assert_empty temporary_files_for(storage_path)
  end

  test "トランザクション中に例外が発生した場合は一時ファイルを元パスへ復元する" do
    drive_item = create_deleted_file(body: "transaction failure")
    storage_path = drive_item.absolute_storage_path
    original_transaction = ActiveRecord::Base.method(:transaction)
    failing_transaction = lambda do |*args, **kwargs, &block|
      original_transaction.call(*args, **kwargs) do
        block.call
        raise ActiveRecord::StatementInvalid, "transaction failed"
      end
    end

    result = nil
    with_singleton_method(ActiveRecord::Base, :transaction, failing_transaction) do
      result = DriveItems::PurgeService.new(drive_item: drive_item).call
    end

    assert_not result.success?
    assert DriveItem.exists?(drive_item.id)
    assert_equal "transaction failure", File.binread(storage_path)
    assert_empty temporary_files_for(storage_path)
  end

  test "コミット失敗時は一時ファイルを元パスへ復元する" do
    drive_item = create_deleted_file(body: "commit failure")
    storage_path = drive_item.absolute_storage_path
    original_transaction = ActiveRecord::Base.method(:transaction)
    failing_commit = lambda do |*args, **kwargs, &block|
      original_transaction.call(*args, **kwargs, &block)
      raise ActiveRecord::StatementInvalid, "commit failed"
    end

    result = nil
    with_singleton_method(ActiveRecord::Base, :transaction, failing_commit) do
      result = DriveItems::PurgeService.new(drive_item: drive_item).call
    end

    assert_not result.success?
    assert_equal "commit failure", File.binread(storage_path)
    assert_empty temporary_files_for(storage_path)
  end

  test "一時ファイルはコミット成功後に削除する" do
    drive_item = create_deleted_file(body: "delete after commit")
    storage_path = drive_item.absolute_storage_path
    inside_transaction = false
    delete_inside_transaction = nil
    transaction = lambda do |*args, **kwargs, &block|
      inside_transaction = true
      block.call
    ensure
      inside_transaction = false
    end
    delete = lambda do |path|
      delete_inside_transaction = inside_transaction
      File.unlink(path.to_s)
    end

    result = nil
    with_singleton_method(ActiveRecord::Base, :transaction, transaction) do
      with_singleton_method(File, :delete, delete) do
        result = DriveItems::PurgeService.new(drive_item: drive_item).call
      end
    end

    assert result.success?
    assert_equal false, delete_inside_transaction, "コミット前に一時ファイルを削除してはいけない"
    assert_not File.exist?(storage_path)
    assert_empty temporary_files_for(storage_path)
  end

  test "コミット後の一時ファイル削除失敗は成功扱いでエラーログを記録する" do
    drive_item = create_deleted_file(body: "cleanup failure")
    storage_path = drive_item.absolute_storage_path
    logger = CapturingLogger.new

    result = nil
    with_singleton_method(Rails, :logger, -> { logger }) do
      with_singleton_method(File, :delete, ->(_path) { raise Errno::EACCES, "denied" }) do
        result = DriveItems::PurgeService.new(drive_item: drive_item).call
      end
    end

    assert result.success?
    assert_not DriveItem.exists?(drive_item.id)
    assert_not_empty temporary_files_for(storage_path)
    assert_equal 1, logger.errors.size
    assert_includes logger.errors.first, "[drive_items.purge] temporary cleanup failed"
    assert_includes logger.errors.first, "drive_item_id=#{drive_item.id}"
    assert_includes logger.errors.first, storage_path.dirname.to_s
    assert_includes logger.errors.first, "error=Errno::EACCES:"
  end

  test "コミット後の一時ファイル削除で ENOENT は正常扱いにする" do
    drive_item = create_deleted_file(body: "cleanup already gone")
    storage_path = drive_item.absolute_storage_path
    logger = Object.new
    def logger.error(message)
      raise "unexpected error log: #{message}"
    end
    delete = lambda do |path|
      File.unlink(path.to_s)
      raise Errno::ENOENT, path
    end

    result = nil
    with_singleton_method(Rails, :logger, -> { logger }) do
      with_singleton_method(File, :delete, delete) do
        result = DriveItems::PurgeService.new(drive_item: drive_item).call
      end
    end

    assert result.success?
    assert_not DriveItem.exists?(drive_item.id)
    assert_empty temporary_files_for(storage_path)
  end

  test "不正な storage_key は拒否する" do
    drive_item = create_deleted_file(body: "invalid key")
    storage_path = drive_item.absolute_storage_path
    drive_item.update_columns(storage_key: "../secret.txt", blob_path: "drive_items/../secret.txt")

    result = DriveItems::PurgeService.new(drive_item: drive_item.reload).call

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert_equal "保存先キーが不正です", result.message
    assert DriveItem.exists?(drive_item.id)
    assert File.exist?(storage_path)
  end

  test "不正な保存先パスは拒否する" do
    drive_item = create_deleted_file(body: "invalid path")
    storage_path = drive_item.absolute_storage_path
    service = DriveItems::PurgeService.new(drive_item: drive_item)

    result = with_singleton_method(service, :verified_storage_path, ->(_storage_key) { nil }) { service.call }

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert_equal "保存先パスが不正です", result.message
    assert DriveItem.exists?(drive_item.id)
    assert File.exist?(storage_path)
  end

  test "実ファイル不存在は拒否する" do
    drive_item = create_deleted_file(body: "missing")
    storage_path = drive_item.absolute_storage_path
    FileUtils.rm_f(storage_path)

    result = DriveItems::PurgeService.new(drive_item: drive_item).call

    assert_not result.success?
    assert_equal :not_found, result.status
    assert_equal "実ファイルが見つかりません", result.message
    assert DriveItem.exists?(drive_item.id)
  end

  test "元ファイルがシンボリックリンクの場合は拒否する" do
    target_path = write_storage_file("#{SecureRandom.uuid}.txt", "target")
    symlink_key = "#{SecureRandom.uuid}.txt"
    symlink_path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(symlink_key))
    FileUtils.mkdir_p(symlink_path.dirname)
    FileUtils.ln_s(target_path, symlink_path)
    @storage_paths << symlink_path
    drive_item = build_deleted_file(storage_key: symlink_key, body: nil)

    result = DriveItems::PurgeService.new(drive_item: drive_item).call

    assert_not result.success?
    assert_equal :not_found, result.status
    assert DriveItem.exists?(drive_item.id)
    assert File.symlink?(symlink_path)
    assert_equal "target", File.binread(target_path)
  end

  test "ディレクトリ削除ではファイル移動処理を行わない" do
    directory = create_deleted_directory
    result = nil

    with_singleton_method(FileUtils, :mv, ->(_from, _to) { raise "directory purge must not move files" }) do
      result = DriveItems::PurgeService.new(drive_item: directory).call
    end

    assert result.success?
    assert_equal "フォルダを完全削除しました", result.message
    assert_not DriveItem.exists?(directory.id)
  end

  test "空でないディレクトリは削除できない" do
    directory = create_deleted_directory
    create_deleted_directory(parent: directory)

    result = DriveItems::PurgeService.new(drive_item: directory).call

    assert_not result.success?
    assert_equal :unprocessable_entity, result.status
    assert_equal "空でないフォルダは完全削除できません", result.message
    assert DriveItem.exists?(directory.id)
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

  def create_deleted_file(body:)
    storage_key = "#{SecureRandom.uuid}.txt"
    write_storage_file(storage_key, body)
    build_deleted_file(storage_key:, body:)
  end

  def build_deleted_file(storage_key:, body:)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      name: "purge-#{SecureRandom.hex(4)}",
      item_type: "file",
      extension: "txt",
      storage_key: storage_key,
      blob_path: DriveItem.storage_relative_path_for(storage_key),
      content_type: "text/plain",
      file_hash: body.present? ? Digest::SHA256.hexdigest(body) : nil,
      file_size: body&.bytesize || 0,
      deleted_at: Time.current
    )
  end

  def create_deleted_directory(parent: nil)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: parent,
      name: "purge-dir-#{SecureRandom.hex(4)}",
      item_type: "directory",
      deleted_at: Time.current
    )
  end

  def write_storage_file(storage_key, body)
    path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body)
    @storage_paths << path
    path
  end

  def temporary_files_for(storage_path)
    Dir.glob("#{storage_path}.purging-*")
  end

  def with_singleton_method(receiver, method_name, implementation)
    singleton_class = class << receiver; self; end
    had_method = singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
    original_method = receiver.method(method_name) if had_method

    receiver.define_singleton_method(method_name, &implementation)
    yield
  ensure
    if had_method
      receiver.define_singleton_method(method_name, original_method)
    else
      singleton_class.remove_method(method_name)
    end
  end
end
