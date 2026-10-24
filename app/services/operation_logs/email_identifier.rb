require "openssl"

module OperationLogs
  class EmailIdentifier
    def self.call(email)
      normalized = Auth::MagicLinks.normalize_email(email)
      return if normalized.blank?

      EmailIdentityKey.verify!
      EmailIdentities::Digest.call(normalized)
    end
  end
end
