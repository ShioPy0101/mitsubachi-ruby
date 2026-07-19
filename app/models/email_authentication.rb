class EmailAuthentication < ApplicationRecord
  PURPOSES = %w[registration login].freeze
  DELIVERY_TOKEN_CIPHER = "aes-256-gcm"
  DELIVERY_TOKEN_SALT = "mitsubachi email authentication delivery token"

  belongs_to :organization_invite, optional: true

  validates :email, :token, :expires_at, :purpose, presence: true
  validates :token, uniqueness: true
  validates :purpose, inclusion: { in: PURPOSES }

  def registration?
    purpose == "registration"
  end

  def login?
    purpose == "login"
  end

  def delivery_token=(raw_token)
    self.delivery_token_ciphertext =
      if raw_token.present?
        self.class.delivery_token_encryptor.encrypt_and_sign(raw_token)
      end
  end

  def delivery_token
    return if delivery_token_ciphertext.blank?

    self.class.delivery_token_encryptor.decrypt_and_verify(delivery_token_ciphertext)
  end

  def self.delivery_token_encryptor
    key = Rails.application.key_generator.generate_key(DELIVERY_TOKEN_SALT, 32)

    ActiveSupport::MessageEncryptor.new(key, cipher: DELIVERY_TOKEN_CIPHER)
  end
end
