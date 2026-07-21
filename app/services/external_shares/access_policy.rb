module ExternalShares
  class AccessPolicy
    SAFE_INLINE_MIME_TYPES = %w[
      image/png
      image/jpeg
      image/gif
      image/webp
      video/mp4
      video/webm
      audio/mpeg
      audio/mp4
      audio/ogg
      application/pdf
      text/plain
    ].freeze

    SAFE_INLINE_EXTENSIONS = %w[png jpg jpeg gif webp mp4 webm mp3 m4a ogg pdf txt].freeze

    def initialize(external_share:)
      @external_share = external_share
    end

    def can_download?(drive_item)
      @external_share.allow_download? && accessible_item?(drive_item) && drive_item.file?
    end

    def can_preview?(drive_item)
      accessible_item?(drive_item) &&
        drive_item.file? &&
        SAFE_INLINE_MIME_TYPES.include?(drive_item.content_type.to_s.downcase) &&
        SAFE_INLINE_EXTENSIONS.include?(drive_item.extension.to_s.downcase)
    end

    def can_bulk_download?
      @external_share.allow_bulk_download?
    end

    def accessible_item?(drive_item)
      ItemScope.new(external_share: @external_share).include?(drive_item)
    end
  end
end
