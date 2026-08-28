require "open3"
require "timeout"

module MediaPreviews
  # FFmpeg を argv 形式で実行し、動画から一覧向け代表 frame を抽出する。
  class VideoGenerator
    DEFAULT_TIMEOUT = 10
    STDERR_LIMIT = 4_000

    class GenerationError < StandardError; end
    class ToolUnavailable < GenerationError; end

    def initialize(ffmpeg_path: ENV.fetch("MEDIA_FFMPEG_PATH", "ffmpeg"), timeout: DEFAULT_TIMEOUT)
      @ffmpeg_path = ffmpeg_path
      @timeout = timeout
    end

    def call(input_path:, output_path:)
      failures = []
      attempts(input_path, output_path).each do |argv|
        success, stderr = run(argv)
        return output_path if success && File.file?(output_path) && File.size?(output_path)

        FileUtils.rm_f(output_path)
        failures << stderr
      end

      raise GenerationError, failures.join(" | ").byteslice(0, STDERR_LIMIT)
    end

    private

    def attempts(input_path, output_path)
      common = [
        "-ss", "3", "-i", input_path.to_s, "-frames:v", "1",
        "-vf", "scale='if(gt(iw,ih),320,-2)':'if(gt(iw,ih),-2,320)':flags=fast_bilinear",
        "-q:v", "6", "-an", "-y", output_path.to_s
      ]
      [
        [ @ffmpeg_path, "-hide_banner", "-loglevel", "error", "-ss", "3", "-skip_frame", "nokey", "-i", input_path.to_s,
         "-frames:v", "1", "-vf", "scale='if(gt(iw,ih),320,-2)':'if(gt(iw,ih),-2,320)':flags=fast_bilinear",
         "-q:v", "6", "-an", "-y", output_path.to_s ],
        [ @ffmpeg_path, "-hide_banner", "-loglevel", "error", *common ]
      ]
    end

    def run(argv)
      stderr_output = ""
      status = nil
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        begin
          status = Timeout.timeout(@timeout) { wait_thread.value }
        rescue Timeout::Error
          terminate(wait_thread.pid)
          raise GenerationError, "FFmpeg timed out after #{@timeout} seconds"
        ensure
          stdout_reader.value
          stderr_output = stderr_reader.value.to_s.byteslice(0, STDERR_LIMIT)
        end
      end
      [ status&.success?, stderr_output ]
    rescue Errno::ENOENT
      raise ToolUnavailable, "FFmpeg is not available: #{@ffmpeg_path}"
    end

    def terminate(pid)
      Process.kill("TERM", pid)
      Timeout.timeout(1) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill("KILL", pid)
    end
  end
end
