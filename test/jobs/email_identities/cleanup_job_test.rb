require "test_helper"

class EmailIdentities::CleanupJobTest < ActiveSupport::TestCase
  test "erases expired recipients and frees expired pending email reservation" do
    auth = EmailAuthentication.create!(email: "test1@example.com", token: "expired-cleanup", expires_at: 1.minute.ago, recipient_ciphertext: "expired-cipher", delivery_token: "token")
    active = EmailAuthentication.create!(email: "test2@example.com", token: "active-cleanup", expires_at: 1.minute.from_now, recipient_ciphertext: "active-cipher")
    change = users(:one).user_email_changes.create!(new_email: "cleanup@example.com", token_digest: "expired-change", expires_at: 1.minute.ago, delivery_addresses_ciphertext: "expired-cipher")
    EmailIdentities::CleanupJob.perform_now
    assert_nil auth.reload.recipient_ciphertext
    assert_nil auth.delivery_token_ciphertext
    assert_equal "active-cipher", active.reload.recipient_ciphertext
    assert_nil change.reload.delivery_addresses_ciphertext
    assert change.cancelled?
    replacement = users(:two).user_email_changes.create!(new_email: "cleanup@example.com", token_digest: "replacement-change", expires_at: 10.minutes.from_now)
    assert replacement.persisted?
  end
end
