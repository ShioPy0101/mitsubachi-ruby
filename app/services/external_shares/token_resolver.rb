require "digest"

module ExternalShares
  class TokenResolver
    def initialize(raw_token:, include_inactive: false)
      @raw_token = raw_token.to_s
      @include_inactive = include_inactive
    end

    def call
      return if @raw_token.blank?

      scope.find_by(token_digest: Digest::SHA256.hexdigest(@raw_token))
    end

    private

    def scope
      @include_inactive ? ExternalShare.all : ExternalShare.active
    end
  end
end
