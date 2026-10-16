require "test_helper"

class UserEmailChangeMailerTest < ActionMailer::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @frontend_url = ENV["FRONTEND_URL"]
    ENV["FRONTEND_URL"] = "https://front.example"
  end

  teardown do
    ENV["FRONTEND_URL"] = @frontend_url
    travel_back
  end

  test "approval mail goes to old address before confirming new address" do
    change = users(:one).user_email_changes.create!(new_email: "new@example.com", token_digest: UserEmailChange.digest_token("approval-token"), expires_at: 30.minutes.from_now)
    mail = UserEmailChangeMailer.with(user: users(:one), email_change: change, old_email: "test1@example.com", token: "approval-token").approval
    assert_equal [ "test1@example.com" ], mail.to
    assert_includes mail.text_part.decoded, "/settings/email-change/approve?token=approval-token"
    assert_includes mail.text_part.decoded, "まだ変更されません"
  end

  test "confirmation mail contains verification link" do
    travel_to Time.zone.local(2026, 7, 24, 12, 0, 0) do
      user = users(:one)
      email_change = user.user_email_changes.create!(
        new_email: "mail-change@example.com",
        token_digest: UserEmailChange.digest_token("mail-change-token"),
        expires_at: 30.minutes.from_now
      )

      mail = UserEmailChangeMailer.with(
        user: user,
        email_change: email_change,
        token: "mail-change-token"
      ).confirmation

      assert_equal [ "mail-change@example.com" ], mail.to
      assert_equal "【Mitsubachi】メールアドレス変更確認", mail.subject
      assert_includes mail.text_part.decoded, "https://front.example/settings/email-change/verify?token=mail-change-token"
      assert_includes mail.text_part.decoded, "有効期限: 2026年7月24日 12:30 JST"
    end
  end

  test "changed notification is sent to old email" do
    travel_to Time.zone.local(2026, 7, 24, 12, 0, 0) do
      mail = UserEmailChangeMailer.with(
        user: users(:one),
        old_email: "old@example.com"
      ).changed_notification

      assert_equal [ "old@example.com" ], mail.to
      assert_equal "【Mitsubachi】メールアドレス変更完了のお知らせ", mail.subject
      assert_includes mail.text_part.decoded, "メールアドレスが変更されました"
      assert_includes mail.text_part.decoded, "変更日時: 2026年7月24日 12:00 JST"
    end
  end
end
