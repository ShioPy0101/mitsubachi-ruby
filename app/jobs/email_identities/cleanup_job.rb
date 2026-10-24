module EmailIdentities
  # 復元可能な宛先を恒久的な連絡先帳にしない。期限後の暗号文も定期的に消去する。
  class CleanupJob < ApplicationJob
    queue_as :maintenance

    def perform
      now = Time.current
      EmailAuthentication.where("expires_at <= ?", now)
                         .where("recipient_ciphertext IS NOT NULL OR delivery_token_ciphertext IS NOT NULL")
                         .update_all(recipient_ciphertext: nil, delivery_token_ciphertext: nil)
      UserEmailChange.active.where("expires_at <= ?", now)
                     .update_all(cancelled_at: now, delivery_addresses_ciphertext: nil, updated_at: now)
      UserEmailChange.where("used_at IS NOT NULL OR cancelled_at IS NOT NULL")
                     .where.not(delivery_addresses_ciphertext: nil)
                     .update_all(delivery_addresses_ciphertext: nil)
    end
  end
end
