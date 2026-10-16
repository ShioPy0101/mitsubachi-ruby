module EmailIdentities
  # 非同期配信・二段階メール変更に必要な宛先だけを、用途と有効期限付きで暗号化する。
  # HMAC鍵とは分離し、既存の配信用tokenと同様にRails key_generatorから専用鍵を導出する。
  class DeliveryPayload
    def self.encrypt(value, purpose:, expires_at:)
      encryptor.encrypt_and_sign(value, purpose: purpose, expires_at: expires_at)
    end

    def self.decrypt(value, purpose:)
      encryptor.decrypt_and_verify(value, purpose: purpose) ||
        raise(ActiveSupport::MessageEncryptor::InvalidMessage, "Email delivery payload expired")
    end

    def self.encryptor
      key = Rails.application.key_generator.generate_key("mitsubachi/email-delivery-payload/v1", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON)
    end
  end
end
