require "digest"

module ExternalShares
  class TokenResolver
    def initialize(raw_token:)
      @raw_token = raw_token.to_s
    end

    def call
      return if @raw_token.blank?

      ExternalShare.active.find_by(token_digest: Digest::SHA256.hexdigest(@raw_token))
    end
  end
end
