require "digest"

module DriveItems
  class IntegrityChecker
    DEFAULT_CHUNK_SIZE = 5.megabytes

    Result = Data.define(
      :exists?,
      :valid?,
      :errors,
      :actual_size,
      :actual_hash,
      :actual_content_type
    )

    def initialize(drive_item:)
      @drive_item = drive_item
    end

    def call
      storage_key = @drive_item.effective_storage_key
      unless DriveItem.valid_storage_key?(storage_key)
        return Result.new(false, false, [ "invalid_storage_key" ], nil, nil, nil)
      end

      path = @drive_item.absolute_storage_path
      unless File.exist?(path)
        return Result.new(false, false, [ "missing_file" ], nil, nil, nil)
      end

      actual_size, actual_hash = self.class.digest_io(File.open(path, "rb"))
      actual_content_type = Marcel::MimeType.for(Pathname.new(path), name: @drive_item.filename)

      errors = []
      errors << "file_size_mismatch" if @drive_item.file_size.present? && @drive_item.file_size != actual_size
      errors << "file_hash_mismatch" if @drive_item.file_hash.present? && @drive_item.file_hash != actual_hash
      errors << "content_type_mismatch" if @drive_item.content_type.present? && @drive_item.content_type != actual_content_type

      Result.new(true, errors.empty?, errors, actual_size, actual_hash, actual_content_type)
    end

    def self.digest_io(io, chunk_size: DEFAULT_CHUNK_SIZE)
      digest = Digest::SHA256.new
      byte_size = 0

      while (chunk = io.read(chunk_size))
        digest.update(chunk)
        byte_size += chunk.bytesize
      end

      [ byte_size, digest.hexdigest ]
    ensure
      io.close if io.respond_to?(:close)
    end
  end
end
