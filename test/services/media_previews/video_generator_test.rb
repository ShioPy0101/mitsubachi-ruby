require "test_helper"
require "fileutils"

class MediaPreviewsVideoGeneratorTest < ActiveSupport::TestCase
  class StubVideoGenerator < MediaPreviews::VideoGenerator
    attr_reader :commands

    def initialize(results)
      super(ffmpeg_path: "ffmpeg-test", timeout: 1)
      @results = results
      @commands = []
    end

    private

    def run(argv)
      @commands << argv
      success = @results.shift
      File.binwrite(argv.last, "jpeg-frame") if success
      [ success, success ? "" : "decode failed" ]
    end
  end

  test "高速keyframe取得に失敗すると通常seekへfallbackする" do
    Dir.mktmpdir do |directory|
      output = File.join(directory, "preview.jpg")
      generator = StubVideoGenerator.new([ false, true ])

      generator.call(input_path: File.join(directory, "input.mp4"), output_path: output)

      assert_equal 2, generator.commands.length
      first = generator.commands.first
      assert_operator first.index("-ss"), :<, first.index("-i")
      assert_includes first, "-skip_frame"
      refute_includes generator.commands.last, "-skip_frame"
      assert_equal "jpeg-frame", File.binread(output)
    end
  end

  test "全attempt失敗時はstderrを含むGenerationErrorを返す" do
    Dir.mktmpdir do |directory|
      error = assert_raises(MediaPreviews::VideoGenerator::GenerationError) do
        StubVideoGenerator.new([ false, false, false ]).call(
          input_path: File.join(directory, "input.mp4"),
          output_path: File.join(directory, "preview.jpg")
        )
      end

      assert_includes error.message, "decode failed"
    end
  end

  test "3秒seekが失敗する短い動画は先頭frameへfallbackする" do
    Dir.mktmpdir do |directory|
      output = File.join(directory, "preview.jpg")
      generator = StubVideoGenerator.new([ false, false, true ])

      generator.call(input_path: File.join(directory, "short.mp4"), output_path: output)

      assert_equal 3, generator.commands.length
      last = generator.commands.last
      assert_equal "0", last.fetch(last.index("-ss") + 1)
      assert_operator last.index("-ss"), :<, last.index("-i")
    end
  end

  test "FFmpegが存在しない場合はToolUnavailableを返す" do
    error = assert_raises(MediaPreviews::VideoGenerator::ToolUnavailable) do
      MediaPreviews::VideoGenerator.new(ffmpeg_path: "/definitely-missing/ffmpeg").call(
        input_path: "/tmp/input.mp4",
        output_path: "/tmp/output.jpg"
      )
    end

    assert_includes error.message, "FFmpeg is not available"
  end
end
