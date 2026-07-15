require "fileutils"
require "tempfile"
require "zip"

module DriveItems
  class BulkDownloadService
    ZIP_CONTENT_TYPE = "application/zip"
    CHUNK_SIZE = 5.megabytes

    Result = Data.define(:success?, :status, :error_message, :zip_path, :filename, :drive_items) do
      def self.success(zip_path:, filename:, drive_items:)
        new(true, :ok, nil, zip_path, filename, drive_items)
      end

      def self.failure(status, error_message)
        new(false, status, error_message, nil, nil, [])
      end
    end

    def initialize(organization:, drive_item_ids:)
      @organization = organization
      @drive_item_ids = Array(drive_item_ids).reject(&:blank?)
    end

    def call
      return Result.failure(:unprocessable_entity, "対象が指定されていません") if @drive_item_ids.empty?

      roots = @organization.drive_items.active.where(id: @drive_item_ids).order(:id).to_a
      return Result.failure(:not_found, "有効な対象が見つかりません") if roots.empty?

      entries = build_entries(roots)
      return Result.failure(:not_found, "ダウンロード可能なファイルが見つかりません") if entries.empty?

      zip_file = Tempfile.new([ "drive-items-", ".zip" ], binmode: true)
      zip_path = zip_file.path
      zip_file.close

      write_zip!(zip_path, entries)
      Result.success(zip_path: zip_path, filename: zip_filename, drive_items: entries.map(&:drive_item))
    rescue InvalidEntryError => error
      cleanup_zip(zip_path)
      Result.failure(error.status, error.message)
    rescue StandardError => error
      cleanup_zip(zip_path)
      Rails.logger.error("[drive_items.bulk_download] failed error=#{error.class}: #{error.message}")
      Result.failure(:unprocessable_entity, "ZIPファイルを作成できませんでした")
    end

    private

    Entry = Data.define(:drive_item, :entry_name, :absolute_path)
    InvalidEntryError = Class.new(StandardError) do
      attr_reader :status

      def initialize(message, status: :unprocessable_entity)
        @status = status
        super(message)
      end
    end

    def build_entries(roots)
      entries = []
      used_entry_names = {}
      included_file_ids = {}

      roots.each do |root|
        collect_file_entries(root, base_components(root), entries, used_entry_names, included_file_ids)
      end

      entries
    end

    def collect_file_entries(drive_item, path_components, entries, used_entry_names, included_file_ids)
      if drive_item.directory?
        drive_item.children.active.order(:item_type, :name, :id).find_each do |child|
          collect_file_entries(child, path_components + [ safe_component(child.name) ], entries, used_entry_names, included_file_ids)
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
          zip.put_next_entry(entry.entry_name)
          File.open(entry.absolute_path, "rb") do |file|
            while (chunk = file.read(CHUNK_SIZE))
              zip.write(chunk)
            end
          end
        end
      end
    end

    def safe_storage_path(drive_item)
      storage_root = Rails.root.join("storage").expand_path.to_s
      absolute_path = drive_item.absolute_storage_path.expand_path.to_s

      unless absolute_path.start_with?("#{storage_root}/")
        raise InvalidEntryError.new("保存先キーが不正なファイルが含まれています", status: :not_found)
      end

      absolute_path
    end

    def unique_entry_name(components, used_entry_names)
      entry_name = components.join("/")
      return used_entry_names[entry_name] = entry_name unless used_entry_names.key?(entry_name)

      dirname = File.dirname(entry_name)
      basename = File.basename(entry_name, ".*")
      extension = File.extname(entry_name)
      index = 2

      loop do
        candidate = [ dirname == "." ? nil : dirname, "#{basename} (#{index})#{extension}" ].compact.join("/")
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
      FileUtils.rm_f(zip_path) if zip_path.present?
    end
  end
end
