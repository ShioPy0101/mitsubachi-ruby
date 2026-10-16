require "fileutils"
require "securerandom"

module MediaPreviews
  # cache hit 判定、file lock、atomic publish と generator 選択をまとめる。
  class Generator
    IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp image/bmp image/tiff image/heic image/avif].freeze

    Result = Data.define(:success?, :status, :error_message, :path, :cache_hit, :generator_type) do
      def self.success(path:, cache_hit:, generator_type:)
        new(true, :ok, nil, path, cache_hit, generator_type)
      end

      def self.failure(status, message, generator_type: nil)
        new(false, status, message, nil, false, generator_type)
      end
    end

    def initialize(drive_item:, image_generator: ImageGenerator.new, video_generator: VideoGenerator.new)
      @drive_item = drive_item
      @cache_path = CachePath.new(drive_item:)
      @image_generator = image_generator
      @video_generator = video_generator
    end

    def call
      type, generator = selected_generator
      return Result.failure(:unsupported_media_type, "このファイル形式のサムネイルには対応していません") unless generator

      return logged_success(type, cache_hit: true) if valid_cache?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      FileUtils.mkdir_p(@cache_path.absolute_path.dirname, mode: 0o755)
      File.open(@cache_path.lock_path, File::RDWR | File::CREAT, 0o640) do |lock|
        lock.flock(File::LOCK_EX)
        return logged_success(type, cache_hit: true) if valid_cache?

        generate_atomic!(generator)
      end
      log(type:, cache_hit: false, success: true, started:)
      Result.success(path: @cache_path.absolute_path, cache_hit: false, generator_type: type)
    rescue VideoGenerator::ToolUnavailable, ImageGenerator::ToolUnavailable => error
      unavailable_type = error.is_a?(VideoGenerator::ToolUnavailable) ? "video" : "image"
      log(type: unavailable_type, cache_hit: false, success: false, started:, error:)
      Result.failure(:service_unavailable, "#{unavailable_type == 'video' ? '動画' : '画像'}サムネイル機能を利用できません", generator_type: unavailable_type)
    rescue StandardError => error
      log(type: type || "unknown", cache_hit: false, success: false, started:, error:)
      Result.failure(:unprocessable_content, "サムネイルを生成できませんでした", generator_type: type)
    end

    private

    def selected_generator
      content_type = @drive_item.content_type.to_s.downcase
      return [ "image", @image_generator ] if IMAGE_TYPES.include?(content_type)
      return [ "video", @video_generator ] if content_type.start_with?("video/")

      [ nil, nil ]
    end

    def valid_cache?
      File.file?(@cache_path.absolute_path) && File.size?(@cache_path.absolute_path)
    end

    def generate_atomic!(generator)
      path = @cache_path.absolute_path
      extension = path.extname.to_s
      basename = path.basename(extension).to_s

      temporary_path = path.dirname.join(
        ".#{basename}.tmp-#{SecureRandom.hex(8)}#{extension}"
      ).to_s

      generator.call(
        input_path: @drive_item.absolute_storage_path.to_s,
        output_path: temporary_path
      )

      raise "generator did not create a preview" unless File.file?(temporary_path) && File.size?(temporary_path)

      File.chmod(0o644, temporary_path)
      File.rename(temporary_path, path.to_s)
    ensure
      FileUtils.rm_f(temporary_path) if temporary_path
    end

    def logged_success(type, cache_hit:)
      log(type:, cache_hit:, success: true)
      Result.success(path: @cache_path.absolute_path, cache_hit:, generator_type: type)
    end

    def log(type:, cache_hit:, success:, started: nil, error: nil)
      duration_ms = started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1) : 0
      message = "[media_previews.generator] organization_id=#{@drive_item.organization_id} " \
                "drive_item_id=#{@drive_item.id} media_type=#{@drive_item.content_type} generator_type=#{type} " \
                "cache_#{cache_hit ? 'hit' : 'miss'} duration_ms=#{duration_ms} success=#{success}"
      message += " error=#{error.class}: #{error.message.to_s.byteslice(0, 1_000)}" if error
      success ? Rails.logger.info(message) : Rails.logger.warn(message)
    end
  end
end
