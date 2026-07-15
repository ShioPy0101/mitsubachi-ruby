require "test_helper"
require "stringio"

class DriveItems::IntegrityCheckerTest < ActiveSupport::TestCase
  setup do
    @drive_item = drive_items(:child_file)
    @storage_key = "#{SecureRandom.uuid}.pdf"
    @drive_item.update_columns(
      storage_key: @storage_key,
      blob_path: DriveItem.storage_relative_path_for(@storage_key)
    )
    FileUtils.mkdir_p(Rails.root.join("storage", "drive_items"))
    File.binwrite(@drive_item.absolute_storage_path, "a" * 32)
  end

  teardown do
    FileUtils.rm_f(@drive_item.absolute_storage_path)
  end

  test "detects missing files" do
    FileUtils.rm_f(@drive_item.absolute_storage_path)

    result = DriveItems::IntegrityChecker.new(drive_item: @drive_item).call

    assert_not result.exists?
    assert_includes result.errors, "missing_file"
  end

  test "digest io reads in chunks" do
    fake_io = ChunkLimitedIO.new("a" * (6.megabytes), 5.megabytes)

    size, hash = DriveItems::IntegrityChecker.digest_io(fake_io, chunk_size: 5.megabytes)

    assert_equal 6.megabytes, size
    assert_equal Digest::SHA256.hexdigest("a" * 6.megabytes), hash
  end

  class ChunkLimitedIO
    def initialize(data, max_chunk_size)
      @io = StringIO.new(data)
      @max_chunk_size = max_chunk_size
    end

    def read(length = nil, *)
      raise "length is required" if length.nil?
      raise "chunk too large" if length > @max_chunk_size

      @io.read(length)
    end

    def close; end
  end
end
