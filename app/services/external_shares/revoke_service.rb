module ExternalShares
  class RevokeService
    Result = Data.define(:success?, :external_share)

    def initialize(external_share:)
      @external_share = external_share
    end

    def call
      @external_share.update!(revoked_at: Time.current) unless @external_share.revoked?
      Result.new(true, @external_share)
    end
  end
end
