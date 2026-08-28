require "digest"
require "fileutils"

module MediaPreviews
  # Preview cache の物理パスと Nginx internal URI を一元的に導出する。
  #
  # HTTP パラメータやファイル名は使わず、DB 上で認可済みの数値 ID と固定値だけから
  # パスを構成する。Original が差し替わった場合は source version が変わり、古い cache を
  # 誤配信しない。cache は DB の正本ではなく、purge 時に item directory ごと削除できる。
  class CachePath
    VERSION = "v1"
    SIZE = 320

    attr_reader :drive_item

    def initialize(drive_item:)
      @drive_item = drive_item
    end

    def absolute_path
      verified_path(preview_root.join(relative_path))
    end

    def lock_path
      # Original version ごとの最終ファイル名に結び付け、別versionの生成・cleanupが
      # lock inode を差し替えて同一Previewの排他を破らないようにする。
      verified_path(absolute_path.dirname.join(".#{absolute_path.basename}.lock"))
    end

    def relative_path
      item_relative_root.join(VERSION, "#{SIZE}-#{source_version}.jpg")
    end

    def internal_uri
      "/internal/previews/#{relative_path}"
    end

    def etag
      Digest::SHA256.hexdigest(
        [ drive_item.id, drive_item.updated_at.to_f, source_version, VERSION, SIZE ].join(":")
      )
    end

    def self.delete_item_cache(organization_id:, drive_item_id:)
      organization_id = Integer(organization_id)
      drive_item_id = Integer(drive_item_id)
      root = preview_root
      path = root.join("organization-#{organization_id}", "drive-item-#{drive_item_id}").expand_path
      return unless path.to_s.start_with?("#{root}/") && path.directory?

      FileUtils.remove_entry_secure(path)
    rescue Errno::ENOENT
      # purge や GC が同じ cache を同時に削除しても、既に消えていれば目的は達成済み。
      nil
    end

    def self.preview_root
      DriveItem.storage_root.join("previews").expand_path
    end

    private

    def preview_root
      self.class.preview_root
    end

    def item_relative_root
      Pathname.new("organization-#{Integer(drive_item.organization_id)}")
        .join("drive-item-#{Integer(drive_item.id)}")
    end

    def source_version
      source = drive_item.file_hash.presence || [ drive_item.updated_at.to_f, drive_item.file_size ].join(":")
      Digest::SHA256.hexdigest(source.to_s).first(16)
    end

    def verified_path(path)
      expanded = path.expand_path
      raise ArgumentError, "Preview cache path is outside preview root" unless expanded.to_s.start_with?("#{preview_root}/")

      expanded
    end
  end
end
