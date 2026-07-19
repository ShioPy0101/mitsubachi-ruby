require "test_helper"

class EmailAuthenticationMailerTest < ActionMailer::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @frontend_url = ENV["FRONTEND_URL"]
    ENV["FRONTEND_URL"] = "https://front.example"
  end

  teardown do
    ENV["FRONTEND_URL"] = @frontend_url
    travel_back
  end

  test "registration link mail clearly describes account registration" do
    travel_to Time.zone.local(2026, 7, 19, 22, 30, 0) do
      organization = organizations(:one)
      raw_token = "registration-mail-token"
      authentication = EmailAuthentication.create!(
        email: "registration-mail@example.com",
        token: Digest::SHA256.hexdigest(raw_token),
        expires_at: 15.minutes.from_now,
        purpose: "registration",
        organization_invite: organization_invites(:one)
      )

      mail = EmailAuthenticationMailer.with(
        email: authentication.email,
        token: raw_token,
        organization: organization,
        authentication: authentication
      ).registration_link

      auth_url = "https://front.example/auth/verify?token=#{raw_token}&purpose=registration"
      text_body = mail.text_part.decoded
      html_body = mail.html_part.decoded

      assert_equal [ "registration-mail@example.com" ], mail.to
      assert_equal "【Mitsubachi】アカウント登録のご案内", mail.subject
      assert mail.text_part.present?
      assert mail.html_part.present?
      assert_includes text_body, "Mitsubachiへのアカウント登録のご案内です。"
      assert_includes text_body, "「#{organization.name}」への招待が届いています。"
      assert_includes text_body, auth_url
      assert_includes text_body, "発行日時: 2026年7月19日 22:30 JST"
      assert_includes text_body, "有効期限: 2026年7月19日 22:45 JST"
      assert_includes text_body, "このリンクは一度使用すると無効になります。"
      assert_includes text_body, "このメールに心当たりがない場合は、リンクを開かずにこのメールを破棄してください。"
      assert_includes text_body, "※このメールは送信専用です。返信いただいても確認できません。"
      assert_includes html_body, "アカウント登録を完了する"
      assert_includes html_body, raw_token
      assert_equal 1, text_body.scan(raw_token).count
      assert_equal 2, html_body.scan(raw_token).count
      assert_operator authentication.created_at, :<, authentication.expires_at
      assert_match(/2026年7月19日 22:30 JST/, text_body)
      refute_includes text_body, "ログインリクエスト"
      refute_includes text_body, "Mitsubachiにログインする"
    end
  end

  test "login link mail clearly describes login" do
    travel_to Time.zone.local(2026, 7, 19, 22, 30, 0) do
      organization = organizations(:two)
      raw_token = "login-mail-token"
      authentication = EmailAuthentication.create!(
        email: "login-mail@example.com",
        token: Digest::SHA256.hexdigest(raw_token),
        expires_at: 15.minutes.from_now,
        purpose: "login"
      )

      mail = EmailAuthenticationMailer.with(
        email: authentication.email,
        token: raw_token,
        organization: organization,
        authentication: authentication
      ).login_link

      auth_url = "https://front.example/auth/verify?token=#{raw_token}&purpose=login"
      text_body = mail.text_part.decoded
      html_body = mail.html_part.decoded

      assert_equal [ "login-mail@example.com" ], mail.to
      assert_equal "【Mitsubachi】ログインリンクのご案内", mail.subject
      assert mail.text_part.present?
      assert mail.html_part.present?
      assert_includes text_body, "Mitsubachiへのログインリクエストを受け付けました。"
      assert_includes text_body, "対象組織: #{organization.name}"
      assert_includes text_body, auth_url
      assert_includes text_body, "発行日時: 2026年7月19日 22:30 JST"
      assert_includes text_body, "有効期限: 2026年7月19日 22:45 JST"
      assert_includes text_body, "このリンクは一度使用すると無効になります。"
      assert_includes text_body, "ログイン操作に心当たりがない場合は、リンクを開かずにこのメールを破棄してください。"
      assert_includes text_body, "パスワード変更などの操作は不要です。"
      assert_includes text_body, "※このメールは送信専用です。返信いただいても確認できません。"
      assert_includes html_body, "Mitsubachiにログインする"
      assert_includes html_body, raw_token
      assert_equal 1, text_body.scan(raw_token).count
      assert_equal 2, html_body.scan(raw_token).count
      assert_operator authentication.created_at, :<, authentication.expires_at
      assert_match(/2026年7月19日 22:30 JST/, text_body)
      refute_includes text_body, "アカウント登録"
      refute_includes text_body, "招待が届いています"
    end
  end
end
