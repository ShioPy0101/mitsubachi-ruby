require "openssl"

module EmailIdentities
  # Devise の case_insensitive_keys / strip_whitespace_keys と既存の正規化を維持する。
  # Gmail 固有の dot / plus 処理や Unicode 正規化は別人を統合し得るため行わない。
  class Digest
    class ConfigurationError < StandardError; end

    def self.normalize(email)
      email.to_s.strip.downcase
    end

    def self.call(email)
      OpenSSL::HMAC.hexdigest("SHA256", key, normalize(email))
    end

    def self.key
      value = ENV["EMAIL_IDENTITY_HMAC_KEY"].presence || Rails.application.credentials[:email_identity_hmac_key]
      unless value.is_a?(String) && value.bytesize >= 32
        raise ConfigurationError, "Configure a dedicated email_identity_hmac_key of at least 32 bytes"
      end

      value
    end

    # ダイジェストを復元できないため、鍵の変更は移行管理側で検知して停止する。
    def self.fingerprint
      OpenSSL::HMAC.hexdigest("SHA256", key, "mitsubachi/email-identity/key-check/v1")
    end
  end
end
