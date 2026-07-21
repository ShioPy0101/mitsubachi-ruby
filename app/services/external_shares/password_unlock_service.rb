module ExternalShares
  class PasswordUnlockService
    Result = Data.define(:success?, :status, :error_code, :error_message)

    def initialize(external_share:, password:)
      @external_share = external_share
      @password = password.to_s
    end

    def call
      return Result.new(false, :not_found, :share_revoked, "この共有リンクは利用できません") if @external_share.revoked?
      return Result.new(false, :not_found, :share_expired, "この共有リンクは利用できません") if @external_share.expires_at.present? && @external_share.expires_at <= Time.current
      return Result.new(true, :ok, nil, nil) unless @external_share.password_required?
      return Result.new(false, :unprocessable_content, :password_required, "パスワードを入力してください") if @password.blank?
      return Result.new(true, :ok, nil, nil) if @external_share.authenticate(@password)

      Result.new(false, :unauthorized, :invalid_password, "パスワードが正しくありません")
    end
  end
end
