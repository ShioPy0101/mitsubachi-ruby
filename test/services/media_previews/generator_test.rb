require "test_helper"
require "fileutils"

class MediaPreviewsGeneratorTest < ActiveSupport::TestCase
  class FakeGenerator
    attr_reader :calls

    def initialize(payload: "jpeg-preview")
      @payload = payload
      @calls = 0
      @mutex = Mutex.new
    end

    def call(input_path:, output_path:)
      assert_local_input(input_path)
      @mutex.synchronize { @calls += 1 }
      File.binwrite(output_path, @payload)
    end

    private

    def assert_local_input(input_path)
      raise "unexpected input" unless input_path.to_s.start_with?(DriveItem.storage_root.to_s)
    end
  end

  setup do
    @item = drive_items(:child_file)
    @storage_key = "preview-generator-#{SecureRandom.uuid}.jpg"
    @item.update_columns(
      storage_key: @storage_key,
      blob_path: DriveItem.storage_relative_path_for(@storage_key),
      content_type: "image/jpeg",
      file_hash: Digest::SHA256.hexdigest(@storage_key),
      file_size: 8
    )
    FileUtils.mkdir_p(@item.absolute_storage_path.dirname)
    File.binwrite(@item.absolute_storage_path, "original")
    @cache_path = MediaPreviews::CachePath.new(drive_item: @item)
  end

  teardown do
    FileUtils.rm_f(@item.absolute_storage_path)
    MediaPreviews::CachePath.delete_item_cache(
      organization_id: @item.organization_id,
      drive_item_id: @item.id
    )
  end

  test "画像previewのcache missでは一時fileからatomicに公開する" do
    image_generator = FakeGenerator.new
    result = build_generator(image_generator:).call

    assert result.success?
    assert_equal false, result.cache_hit
    assert_equal "image", result.generator_type
    assert_equal "jpeg-preview", File.binread(@cache_path.absolute_path)
    assert_empty Dir.glob(@cache_path.absolute_path.dirname.join("*.tmp-*").to_s)
  end

  test "cache hitではgeneratorを再実行しない" do
    image_generator = FakeGenerator.new
    assert build_generator(image_generator:).call.success?

    result = build_generator(image_generator:).call

    assert result.success?
    assert result.cache_hit
    assert_equal 1, image_generator.calls
  end

  test "同一previewへの同時requestは1回だけ生成する" do
    image_generator = FakeGenerator.new
    generator = build_generator(image_generator:)

    results = 5.times.map { Thread.new { generator.call } }.map(&:value)

    assert results.all?(&:success?)
    assert_equal 1, image_generator.calls
  end

  test "動画はvideo generatorを選択する" do
    @item.update_columns(content_type: "video/mp4")
    video_generator = FakeGenerator.new(payload: "video-frame")

    result = build_generator(video_generator:).call

    assert result.success?
    assert_equal "video", result.generator_type
    assert_equal "video-frame", File.binread(MediaPreviews::CachePath.new(drive_item: @item).absolute_path)
  end

  test "非対応mediaは生成せずunsupportedを返す" do
    @item.update_columns(content_type: "application/pdf")

    result = build_generator.call

    refute result.success?
    assert_equal :unsupported_media_type, result.status
  end

  test "generator failureはDriveItemを変更せずfailureを返す" do
    failure = Object.new
    failure.define_singleton_method(:call) { |**| raise "decode failed" }
    original_updated_at = @item.updated_at

    result = build_generator(image_generator: failure).call

    refute result.success?
    assert_equal :unprocessable_content, result.status
    assert_equal original_updated_at, @item.reload.updated_at
  end

  private

  def build_generator(image_generator: FakeGenerator.new, video_generator: FakeGenerator.new)
    MediaPreviews::Generator.new(drive_item: @item, image_generator:, video_generator:)
  end
end
