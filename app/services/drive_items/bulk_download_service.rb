require "fileutils"
require "pathname"
require "securerandom"
require "zip"

module DriveItems
  class BulkDownloadService
    # rubyzipは入力を逐次圧縮できるため、ファイル総容量をRubyメモリへ展開せず一時ZIPへ書き込む。
    # 現時点では容量上限がないので、同時実行数や巨大フォルダ次第でtmp領域を枯渇させるリスクが残る。
    BULK_DOWNLOAD_DIRECTORY = Rails.root.join("tmp", "bulk_downloads").expand_path.freeze
    ZIP_CONTENT_TYPE = "application/zip"
    CHUNK_SIZE = 5.megabytes

    Result = Data.define(:success?, :status, :error_message, :zip_path, :filename, :drive_items, :file_count, :directory_count, :total_size) do
      def self.bulk_download_directory
        BulkDownloadService::BULK_DOWNLOAD_DIRECTORY
      end

      def self.success(zip_path:, filename:, drive_items:, file_count: 0, directory_count: 0, total_size: 0)
        new(true, :ok, nil, zip_path, filename, drive_items, file_count, directory_count, total_size)
      end

      def self.failure(status, error_message)
        new(false, status, error_message, nil, nil, [], 0, 0, 0)
      end

      def cleanup!
        path = safe_zip_path
        return unless path

        FileUtils.rm_f(path)
      end

      def zip_size
        path = safe_zip_path
        raise ArgumentError, "invalid zip path" unless path

        File.size(path)
      end

      def each_chunk
        path = safe_zip_path
        raise ArgumentError, "invalid zip path" unless path

        File.open(path, "rb") do |file|
          while (chunk = file.read(BulkDownloadService::CHUNK_SIZE))
            yield chunk
          end
        end
      end

      private

      def safe_zip_path
        return if zip_path.blank?

        directory = self.class.bulk_download_directory
        path = Pathname.new(zip_path).expand_path
        relative_path = path.relative_path_from(directory)

        return if relative_path.to_s.start_with?("..")
        return unless path.extname == ".zip"

        path
      rescue ArgumentError
        nil
      end
    end

    def initialize(organization:, drive_item_ids: nil, drive_items: nil, filename: nil)
      @organization = organization
      @drive_item_ids = Array(drive_item_ids).reject(&:blank?)
      @drive_items = drive_items
      @filename = filename
    end

    def call
      return Result.failure(:unprocessable_content, "対象が指定されていません") if @drive_item_ids.empty? && @drive_items.blank?

      roots = @drive_items.presence || @organization.drive_items.active.where(id: @drive_item_ids).order(:id).to_a
      return Result.failure(:not_found, "有効な対象が見つかりません") if roots.empty?

      entries = build_entries(roots)
      return Result.failure(:not_found, "ダウンロード可能なファイルが見つかりません") if entries.empty?

      zip_path = build_zip_path

      write_zip!(zip_path, entries)
      files = entries.reject(&:directory?)
      Result.success(
        zip_path: zip_path,
        filename: @filename.presence || zip_filename,
        drive_items: files.map(&:drive_item),
        file_count: files.size,
        directory_count: entries.count(&:directory?),
        total_size: files.sum { |entry| entry.drive_item.file_size.to_i }
      )
    rescue InvalidEntryError => error
      cleanup_zip(zip_path)
      Result.failure(error.status, error.message)
    rescue StandardError => error
      cleanup_zip(zip_path)
      SystemEvents::Recorder.record!(
        event_type: "storage.archive_generation_failed",
        severity: "error",
        source: "storage",
        organization: @organization,
        error: error,
        metadata: { requested_count: @drive_item_ids&.size || @drive_items&.size }
      )
      Rails.logger.error("[drive_items.bulk_download] failed error=#{error.class}: #{error.message}")
      Result.failure(:internal_server_error, "ZIPファイルを作成できませんでした")
    end

    private

    Entry = Data.define(:drive_item, :entry_name, :absolute_path) do
      def directory?
        drive_item.directory?
      end
    end
    InvalidEntryError = Class.new(StandardError) do
      attr_reader :status

      def initialize(message, status: :unprocessable_content)
        @status = status
        super(message)
      end
    end

    def build_zip_path
      FileUtils.mkdir_p(BULK_DOWNLOAD_DIRECTORY)
      BULK_DOWNLOAD_DIRECTORY.join("bulk-download-#{SecureRandom.uuid}.zip")
    end

    def build_entries(roots)
      entries = []
      used_entry_names = {}
      included_file_ids = {}
      active_items = @organization.drive_items.active.order(:item_type, :name, :id).to_a
      children_by_parent_id = active_items.group_by(&:parent_id)

      roots.each do |root|
        collect_entries(root, base_components(root), entries, used_entry_names, included_file_ids, children_by_parent_id)
      end

      entries
    end

    def collect_entries(drive_item, path_components, entries, used_entry_names, included_file_ids, children_by_parent_id)
      if drive_item.directory?
        entry_name = unique_entry_name(path_components, used_entry_names, directory: true)
        entries << Entry.new(drive_item, entry_name, nil)
        children_by_parent_id.fetch(drive_item.id, []).each do |child|
          collect_entries(child, path_components + [ safe_component(child.name) ], entries, used_entry_names, included_file_ids, children_by_parent_id)
        end
        return
      end

      return if included_file_ids[drive_item.id]

      storage_key = drive_item.effective_storage_key
      unless DriveItem.valid_storage_key?(storage_key)
        raise InvalidEntryError.new("保存先キーが不正なファイルが含まれています", status: :not_found)
      end

      absolute_path = safe_storage_path(drive_item)
      unless File.file?(absolute_path)
        raise InvalidEntryError.new("実ファイルが見つからないファイルが含まれています", status: :not_found)
      end

      included_file_ids[drive_item.id] = true
      entry_name = unique_entry_name(path_components[0...-1] + [ safe_component(drive_item_filename(drive_item)) ], used_entry_names)
      entries << Entry.new(drive_item, entry_name, absolute_path)
    end

    def base_components(root)
      return [ safe_component(root.name) ] if root.directory?

      [ safe_component(drive_item_filename(root)) ]
    end

    def write_zip!(zip_path, entries)
      Zip::OutputStream.open(zip_path) do |zip|
        entries.each do |entry|
          zip.put_next_entry(zip_entry(entry.entry_name))
          next if entry.directory?

          File.open(entry.absolute_path, "rb") do |file|
            while (chunk = file.read(CHUNK_SIZE))
              zip.write(chunk)
            end
          end
        end
      end
    end

    def zip_entry(entry_name)
      entry = Zip::Entry.new("", entry_name)
      # ZIP仕様のEFSビットを項目ごとに立て、グローバルなrubyzip設定を変更せずUTF-8名を保証する。
      entry.gp_flags |= Zip::Entry::EFS
      entry
    end

    def safe_storage_path(drive_item)
      storage_root = DriveItem.storage_root.expand_path.to_s
      absolute_path = drive_item.absolute_storage_path.expand_path.to_s

      unless absolute_path.start_with?("#{storage_root}/")
        raise InvalidEntryError.new("保存先キーが不正なファイルが含まれています", status: :not_found)
      end

      real_path = Pathname.new(absolute_path).realpath.to_s
      unless real_path.start_with?("#{storage_root}/")
        raise InvalidEntryError.new("保存先キーが不正なファイルが含まれています", status: :not_found)
      end

      absolute_path
    rescue Errno::ENOENT
      raise InvalidEntryError.new("実ファイルが見つからないファイルが含まれています", status: :not_found)
    end

    def unique_entry_name(components, used_entry_names, directory: false)
      entry_name = components.join("/")
      entry_name = "#{entry_name}/" if directory
      return used_entry_names[entry_name] = entry_name unless used_entry_names.key?(entry_name)

      collision_name = entry_name.delete_suffix("/")
      dirname = File.dirname(collision_name)
      basename = File.basename(collision_name, ".*")
      extension = File.extname(entry_name)
      index = 2

      loop do
        candidate = [ dirname == "." ? nil : dirname, "#{basename} (#{index})#{extension}" ].compact.join("/")
        candidate = "#{candidate}/" if directory
        return used_entry_names[candidate] = candidate unless used_entry_names.key?(candidate)

        index += 1
      end
    end

    def safe_component(value)
      component = value.to_s.delete("\0\r\n").tr("/\\", "_")
      component = component.gsub("..", "__").strip
      component = "unnamed" if component.blank? || component == "."
      component
    end

    def drive_item_filename(drive_item)
      extension = drive_item.extension.to_s
      return drive_item.name if extension.blank?
      return drive_item.name if drive_item.name.downcase.end_with?(".#{extension.downcase}")

      "#{drive_item.name}.#{extension}"
    end

    def zip_filename
      "drive-items-#{Time.current.strftime('%Y%m%d%H%M%S')}.zip"
    end

    def cleanup_zip(zip_path)
      Result.success(zip_path: zip_path, filename: nil, drive_items: []).cleanup!
    end
  end
end
