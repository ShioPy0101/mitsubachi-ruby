require "test_helper"
require "tempfile"
require "fileutils"

class DriveItems::StoredFileInspectorTest < ActiveSupport::TestCase
  setup do
    @storage_key = "#{SecureRandom.uuid}.txt"
    @storage_path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(@storage_key))
    @uploaded = tempfile_with("atomic upload body")
  end

  teardown do
    @uploaded.close
    @uploaded.unlink
    FileUtils.rm_f(@storage_path)
    Dir.glob(@storage_path.dirname.join(".#{@storage_path.basename}.upload-*.tmp")).each { |path| FileUtils.rm_f(path) }
  end

  test "copy_upload writes temporary file and publishes with rename" do
    result = DriveItems::StoredFileInspector.copy_upload!(
      uploaded_file: upload_wrapper(@uploaded),
      storage_path: @storage_path,
      filename: "sample.txt",
      storage_key: @storage_key
    )

    assert_not File.exist?(@storage_path)
    assert File.exist?(result.temporary_path)
    assert_equal Digest::SHA256.hexdigest("atomic upload body"), result.sha256
    assert_equal "atomic upload body".bytesize, result.byte_size

    result.publish!

    assert File.exist?(@storage_path)
    assert_not File.exist?(result.temporary_path)
    assert_equal "atomic upload body", File.binread(@storage_path)
    assert_equal 0o644, File.stat(@storage_path).mode & 0o777
  end

  test "copy_upload removes temporary file when streaming fails" do
    failing_tempfile = tempfile_with("partial")
    failing_tempfile.define_singleton_method(:read) { |*| raise IOError, "forced read failure" }
    wrapper = upload_wrapper(failing_tempfile)

    assert_raises(IOError) do
      DriveItems::StoredFileInspector.copy_upload!(
        uploaded_file: wrapper,
        storage_path: @storage_path,
        filename: "sample.txt",
        storage_key: @storage_key
      )
    end

    assert_not File.exist?(@storage_path)
    assert_empty Dir.glob(@storage_path.dirname.join(".#{@storage_path.basename}.upload-*.tmp"))
  ensure
    failing_tempfile.close
    failing_tempfile.unlink
  end

  test "copy_upload preserves binary bytes without UTF-8 conversion" do
    binary_body = "\xFF\xD8\x00\xE1binary".b
    binary_tempfile = tempfile_with(binary_body)
    result = DriveItems::StoredFileInspector.copy_upload!(
      uploaded_file: upload_wrapper(binary_tempfile, content_type: "audio/mpeg"),
      storage_path: @storage_path,
      filename: "sample.mp3",
      storage_key: @storage_key
    )

    assert_equal Digest::SHA256.hexdigest(binary_body), result.sha256
    assert_equal binary_body.bytesize, result.byte_size

    result.publish!

    assert_equal binary_body, File.binread(@storage_path)
  ensure
    binary_tempfile&.close
    binary_tempfile&.unlink
  end

  private

  def tempfile_with(body)
    tempfile = Tempfile.new("stored-file-inspector")
    tempfile.binmode
    tempfile.write(body)
    tempfile.rewind
    tempfile
  end

  def upload_wrapper(tempfile, content_type: "text/plain")
    Struct.new(:tempfile, :content_type).new(tempfile, content_type)
  end
end
