require "test_helper"
require "fileutils"

class DriveItems::BulkDownloadServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @organization = @user.organization
    @created_paths = []
  end

  teardown do
    @created_paths.each { |path| FileUtils.rm_f(path) }
  end

  test "ZIPの物理パスは固定一時ディレクトリ配下でサーバー生成名になる" do
    drive_item = create_file_item(name: "visible-name.txt", body: "content")

    result = DriveItems::BulkDownloadService.new(
      organization: @organization,
      drive_item_ids: [ drive_item.id ]
    ).call

    assert result.success?
    zip_path = Pathname.new(result.zip_path)
    relative_path = zip_path.relative_path_from(DriveItems::BulkDownloadService::BULK_DOWNLOAD_DIRECTORY)

    assert_equal DriveItems::BulkDownloadService::BULK_DOWNLOAD_DIRECTORY, zip_path.dirname
    assert_match(/\Abulk-download-[0-9a-f-]{36}\.zip\z/, zip_path.basename.to_s)
    assert_equal relative_path.basename.to_s, zip_path.basename.to_s
    assert_no_match(/visible-name|user-input-id|#{drive_item.id}/, zip_path.basename.to_s)
  ensure
    result&.cleanup!
  end

  test "cleanup! は正規のZIPを削除する" do
    result = result_for_path(write_bulk_zip("valid.zip"))

    result.cleanup!

    assert_not File.exist?(result.zip_path)
  end

  test "cleanup! は固定ディレクトリ外のファイルを削除しない" do
    path = Rails.root.join("tmp", "outside-bulk.zip")
    File.binwrite(path, "zip")
    result = result_for_path(path)

    result.cleanup!

    assert File.exist?(path)
  ensure
    FileUtils.rm_f(path)
  end

  test "cleanup! は親ディレクトリ参照を含むパスを削除しない" do
    path = Rails.root.join("tmp", "bulk-download-parent.zip")
    File.binwrite(path, "zip")
    malicious_path = DriveItems::BulkDownloadService::BULK_DOWNLOAD_DIRECTORY.join("..", "bulk-download-parent.zip")
    result = result_for_path(malicious_path)

    result.cleanup!

    assert File.exist?(path)
  ensure
    FileUtils.rm_f(path)
  end

  test "cleanup! はzip以外を削除しない" do
    path = write_bulk_zip("not-zip.txt")
    result = result_for_path(path)

    result.cleanup!

    assert File.exist?(path)
  end

  private

  def create_file_item(name:, body:)
    extension = File.extname(name).delete_prefix(".").presence || "txt"
    storage_key = "#{SecureRandom.uuid}.#{extension}"
    storage_path = Rails.root.join("storage", DriveItem.storage_relative_path_for(storage_key))
    FileUtils.mkdir_p(storage_path.dirname)
    File.binwrite(storage_path, body)
    @created_paths << storage_path

    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      name: name,
      item_type: "file",
      extension: extension,
      blob_path: storage_key,
      storage_key: storage_key
    )
  end

  def write_bulk_zip(filename)
    directory = DriveItems::BulkDownloadService::BULK_DOWNLOAD_DIRECTORY
    FileUtils.mkdir_p(directory)
    path = directory.join(filename)
    File.binwrite(path, "zip")
    @created_paths << path
    path
  end

  def result_for_path(path)
    DriveItems::BulkDownloadService::Result.success(
      zip_path: path,
      filename: "download.zip",
      drive_items: []
    )
  end
end
