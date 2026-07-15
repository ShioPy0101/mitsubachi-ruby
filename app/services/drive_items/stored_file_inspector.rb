require "digest"

module DriveItems
  class StoredFileInspector
    DEFAULT_CHUNK_SIZE = 5.megabytes
    Result = Data.define(:storage_key, :byte_size, :sha256, :content_type)

    def self.copy_upload!(uploaded_file:, storage_path:, filename:, storage_key:)
      digest = Digest::SHA256.new
      byte_size = 0

      FileUtils.mkdir_p(storage_path.dirname)
      uploaded_file.tempfile.rewind

      File.open(storage_path, "wb") do |destination|
        while (chunk = uploaded_file.tempfile.read(DEFAULT_CHUNK_SIZE))
          destination.write(chunk)
          digest.update(chunk)
          byte_size += chunk.bytesize
        end
      end

      content_type = Marcel::MimeType.for(
        Pathname.new(storage_path),
        name: filename,
        declared_type: uploaded_file.content_type
      )

      Result.new(storage_key, byte_size, digest.hexdigest, content_type)
    ensure
      uploaded_file.tempfile.rewind
    end
  end
end
