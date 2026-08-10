require "digest"
require "securerandom"

module DriveItems
  class StoredFileInspector
    DEFAULT_CHUNK_SIZE = 5.megabytes
    PUBLISHED_FILE_MODE = 0o644
    Result = Data.define(:storage_key, :byte_size, :sha256, :content_type, :temporary_path, :storage_path) do
      def publish!
        FileUtils.mkdir_p(storage_path.dirname)
        # 本番では Rails と X-Accel-Redirect を処理する Nginx が別ユーザー/別コンテナになる。
        # staging 中は 0600 で未公開に保ち、公開直前に Nginx が読める mode へ変更してから
        # rename することで、final path に読めないファイルを出さない。
        File.chmod(DriveItems::StoredFileInspector::PUBLISHED_FILE_MODE, temporary_path)
        File.rename(temporary_path, storage_path)
      end

      def cleanup_temporary!
        FileUtils.rm_f(temporary_path)
      end
    end

    def self.copy_upload!(uploaded_file:, storage_path:, filename:, storage_key:)
      digest = Digest::SHA256.new
      byte_size = 0
      temporary_path = temporary_path_for(storage_path)

      FileUtils.mkdir_p(storage_path.dirname)
      uploaded_file.tempfile.rewind
      uploaded_file.tempfile.binmode

      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o600) do |destination|
        destination.binmode
        while (chunk = uploaded_file.tempfile.read(DEFAULT_CHUNK_SIZE))
          destination.write(chunk)
          digest.update(chunk)
          byte_size += chunk.bytesize
          raise UploadTooLargeError if byte_size > Rails.configuration.x.max_upload_size_bytes
        end
      end

      content_type = Marcel::MimeType.for(
        Pathname.new(temporary_path),
        name: filename,
        declared_type: uploaded_file.content_type
      )

      Result.new(storage_key, byte_size, digest.hexdigest, content_type, temporary_path, storage_path)
    rescue StandardError
      FileUtils.rm_f(temporary_path) if temporary_path
      raise
    ensure
      uploaded_file.tempfile.rewind
    end

    def self.temporary_path_for(storage_path)
      storage_path.dirname.join(".#{storage_path.basename}.upload-#{SecureRandom.uuid}.tmp")
    end

    UploadTooLargeError = Class.new(StandardError)
  end
end
