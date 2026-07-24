require "test_helper"

class UserEmailChangeTest < ActiveSupport::TestCase
  test "normalizes new email" do
    email_change = users(:one).user_email_changes.create!(
      new_email: " NewEmail@Example.com ",
      token_digest: UserEmailChange.digest_token("normalize-token"),
      expires_at: 30.minutes.from_now
    )

    assert_equal "newemail@example.com", email_change.new_email
  end

  test "stores only token digest" do
    raw_token, token_digest = UserEmailChange.generate_token_pair

    email_change = users(:one).user_email_changes.create!(
      new_email: "digest@example.com",
      token_digest: token_digest,
      expires_at: 30.minutes.from_now
    )

    assert_equal Digest::SHA256.hexdigest(raw_token), email_change.token_digest
    assert_not_equal raw_token, email_change.token_digest
  end

  test "detects expiration" do
    email_change = users(:one).user_email_changes.build(
      new_email: "expired-model@example.com",
      token_digest: UserEmailChange.digest_token("expired-model-token"),
      expires_at: Time.current
    )

    assert email_change.expired?(1.second.from_now)
  end

  test "rejects current email and used email" do
    current = users(:one).user_email_changes.build(
      new_email: users(:one).email,
      token_digest: UserEmailChange.digest_token("current-email-token"),
      expires_at: 30.minutes.from_now
    )
    duplicate = users(:one).user_email_changes.build(
      new_email: users(:two).email,
      token_digest: UserEmailChange.digest_token("duplicate-email-token"),
      expires_at: 30.minutes.from_now
    )

    assert_not current.valid?
    assert_not duplicate.valid?
  end
end
