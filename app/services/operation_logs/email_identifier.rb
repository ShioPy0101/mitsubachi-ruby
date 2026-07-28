require "openssl"

module OperationLogs
  class EmailIdentifier
    def self.call(email)
      normalized = Auth::MagicLinks.normalize_email(email)
      return if normalized.blank?

      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, normalized)
    end
  end
end
