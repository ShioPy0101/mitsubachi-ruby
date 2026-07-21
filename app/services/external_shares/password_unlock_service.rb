module ExternalShares
  class PasswordUnlockService
    Result = Data.define(:success?, :status, :error_message)

    def initialize(external_share:, password:)
      @external_share = external_share
      @password = password.to_s
    end

    def call
      return Result.new(true, :ok, nil) unless @external_share.password_required?
      return Result.new(true, :ok, nil) if @external_share.authenticate(@password)

      Result.new(false, :not_found, "この共有リンクは利用できません")
    end
  end
end
