require "test_helper"

class EmailAuthenticationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "should require params for create" do
    post api_v1_auth_create_url
    assert_response :bad_request
  end

  test "should require params for verify" do
    post api_v1_auth_verify_url
    assert_response :bad_request
  end

  test "login rejects provisional invite user" do
    user = User.create!(
      organization: organizations(:one),
      email: "pending@example.com",
      password: "password123"
    )
    OrganizationInvite.create!(
      organization: organizations(:one),
      code: "pending-invite",
      expires_at: 1.day.from_now,
      stand_by_user: user,
      stand_by_at: 1.minute.ago
    )

    assert_difference "AuditEvent.where(action: 'auth.login_link.create', outcome: 'failure').count", 1 do
      assert_no_difference "EmailAuthentication.count" do
        post api_v1_auth_login_url, params: { email: "pending@example.com" }
      end
    end

    assert_response :unauthorized
  end

  test "login rejects suspended user" do
    user = User.create!(
      organization: organizations(:one),
      email: "suspended-login@example.com",
      password: "password123",
      suspended_at: Time.current
    )

    assert_no_difference "EmailAuthentication.count" do
      post api_v1_auth_login_url, params: { email: user.email }
    end

    assert_response :unauthorized
    assert_equal({ "error" => "このユーザーは停止されています" }, response.parsed_body)
  end

  test "create reuses stale provisional user" do
    user = User.create!(
      organization: organizations(:one),
      email: "stale@example.com",
      password: "password123"
    )
    stale_invite = OrganizationInvite.create!(
      organization: organizations(:one),
      code: "stale-invite",
      expires_at: 1.day.from_now,
      stand_by_user: user,
      stand_by_at: 20.minutes.ago
    )
    invite = OrganizationInvite.create!(
      organization: organizations(:two),
      code: "fresh-invite",
      expires_at: 1.day.from_now
    )

    assert_difference "EmailAuthentication.count", 1 do
      assert_difference "AuditEvent.where(action: 'auth.registration_link.create').count", 1 do
        post api_v1_auth_create_url, params: {
          email: " stale@example.com ",
          invite_code: "fresh-invite"
        }
      end
    end

    assert_response :ok
    assert_equal organizations(:two), user.reload.organization
    assert_nil stale_invite.reload.stand_by_user
    assert_equal user, invite.reload.stand_by_user
    assert invite.stand_by_at.present?
  end

  test "create does not move registered user to another organization" do
    user = User.create!(
      organization: organizations(:one),
      email: "registered@example.com",
      password: "password123"
    )
    invite = OrganizationInvite.create!(
      organization: organizations(:two),
      code: "other-org-invite",
      expires_at: 1.day.from_now
    )

    assert_no_difference "EmailAuthentication.count" do
      post api_v1_auth_create_url, params: {
        email: "registered@example.com",
        invite_code: invite.code
      }
    end

    assert_response :conflict
    assert_equal organizations(:one), user.reload.organization
    assert_nil invite.reload.stand_by_user
  end

  test "create rolls back stand-by state when authentication creation fails" do
    invite = OrganizationInvite.create!(
      organization: organizations(:one),
      code: "rollback-invite",
      expires_at: 1.day.from_now
    )
    original_create = EmailAuthentication.method(:create!)

    EmailAuthentication.define_singleton_method(:create!) do |*|
      raise ActiveRecord::RecordInvalid.new(EmailAuthentication.new)
    end

    assert_no_difference "User.count" do
      post api_v1_auth_create_url, params: {
        email: "rollback@example.com",
        invite_code: invite.code
      }
    end

    assert_response :unprocessable_entity
  ensure
    EmailAuthentication.define_singleton_method(:create!, original_create)
    assert_nil invite.reload.stand_by_user
    assert_nil invite.stand_by_at
  end

  test "same active invite cannot create multiple stand-by requests" do
    invite = OrganizationInvite.create!(
      organization: organizations(:one),
      code: "single-standby-invite",
      expires_at: 1.day.from_now
    )

    assert_difference "EmailAuthentication.count", 1 do
      post api_v1_auth_create_url, params: {
        email: "first-standby@example.com",
        invite_code: invite.code
      }
    end
    assert_response :ok

    assert_no_difference "EmailAuthentication.count" do
      post api_v1_auth_create_url, params: {
        email: "second-standby@example.com",
        invite_code: invite.code
      }
    end
    assert_response :conflict
  end

  test "login expires previous active login tokens for same email" do
    user = User.create!(
      organization: organizations(:one),
      email: "repeat-login@example.com",
      password: "password123"
    )
    old_authentication = EmailAuthentication.create!(
      email: user.email,
      token: Digest::SHA256.hexdigest("old-login-token"),
      expires_at: 15.minutes.from_now
    )

    assert_difference "EmailAuthentication.count", 1 do
      post api_v1_auth_login_url, params: { email: " REPEAT-LOGIN@example.com " }
    end

    assert_response :ok
    assert old_authentication.reload.used_at.present?
  end

  test "verify invite magic link marks invite and authentication used" do
    user = User.create!(
      organization: organizations(:one),
      email: "verified@example.com",
      password: "password123"
    )
    invite = OrganizationInvite.create!(
      organization: organizations(:one),
      code: "verify-invite",
      expires_at: 1.day.from_now,
      stand_by_user: user,
      stand_by_at: 1.minute.ago
    )
    raw_token = "verify-token"
    authentication = EmailAuthentication.create!(
      email: "verified@example.com",
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      organization_invite: invite
    )

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :ok
    assert authentication.reload.used_at.present?
    assert invite.reload.used_at.present?
    assert_equal user, invite.used_by_user
    assert_nil invite.stand_by_user
    assert_nil invite.stand_by_at
  end

  test "verify login magic link works with normalized email lookup" do
    user = User.create!(
      organization: organizations(:one),
      email: "mixedcase@example.com",
      password: "password123"
    )
    raw_token = "login-token"
    authentication = EmailAuthentication.create!(
      email: " MixedCase@Example.com ",
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now
    )

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :ok
    assert authentication.reload.used_at.present?
    assert_equal user.id, response.parsed_body.dig("user", "id")
  end

  test "verify rejects used token" do
    raw_token = "used-token"
    EmailAuthentication.create!(
      email: users(:one).email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      used_at: Time.current
    )

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :unauthorized
    assert_equal({ "error" => "このリンクは既に使用されています" }, response.parsed_body)
  end

  test "verify rejects expired token without marking used" do
    raw_token = "expired-token"
    authentication = EmailAuthentication.create!(
      email: users(:one).email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 1.second.ago
    )

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :unauthorized
    assert_equal({ "error" => "リンクの有効期限が切れています" }, response.parsed_body)
    assert_nil authentication.reload.used_at
  end

  test "login link issued before suspension cannot be verified and is consumed" do
    user = User.create!(
      organization: organizations(:one),
      email: "suspend-after-link@example.com",
      password: "password123"
    )
    raw_token = "pre-suspend-token"
    authentication = EmailAuthentication.create!(
      email: user.email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now
    )
    user.update!(suspended_at: Time.current)

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :unauthorized
    assert_equal({ "error" => "このユーザーは停止されています" }, response.parsed_body)
    assert authentication.reload.used_at.present?
  end

  test "registration link cannot be verified after stand-by user is suspended and is consumed" do
    user = User.create!(
      organization: organizations(:one),
      email: "suspended-standby@example.com",
      password: "password123",
      suspended_at: Time.current
    )
    invite = OrganizationInvite.create!(
      organization: organizations(:one),
      code: "suspended-standby-invite",
      expires_at: 1.day.from_now,
      stand_by_user: user,
      stand_by_at: 1.minute.ago
    )
    raw_token = "suspended-registration-token"
    authentication = EmailAuthentication.create!(
      email: user.email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      organization_invite: invite
    )

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :unauthorized
    assert_equal({ "error" => "このユーザーは停止されています" }, response.parsed_body)
    assert authentication.reload.used_at.present?
    assert_nil invite.reload.used_at
  end

  test "same token cannot be verified twice" do
    raw_token = "single-use-token"
    authentication = EmailAuthentication.create!(
      email: users(:one).email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now
    )

    post api_v1_auth_verify_url, params: { token: raw_token }
    assert_response :ok
    assert authentication.reload.used_at.present?

    post api_v1_auth_verify_url, params: { token: raw_token }
    assert_response :unauthorized
    assert_equal({ "error" => "このリンクは既に使用されています" }, response.parsed_body)
  end

  test "registration verify fails without using invite when stand-by user mismatches" do
    correct_user = User.create!(
      organization: organizations(:one),
      email: "correct-standby@example.com",
      password: "password123"
    )
    wrong_user = User.create!(
      organization: organizations(:one),
      email: "wrong-standby@example.com",
      password: "password123"
    )
    invite = OrganizationInvite.create!(
      organization: organizations(:one),
      code: "mismatch-invite",
      expires_at: 1.day.from_now,
      stand_by_user: wrong_user,
      stand_by_at: 1.minute.ago
    )
    raw_token = "mismatch-token"
    authentication = EmailAuthentication.create!(
      email: correct_user.email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      organization_invite: invite
    )

    post api_v1_auth_verify_url, params: { token: raw_token }

    assert_response :unauthorized
    assert_nil invite.reload.used_at
    assert_nil authentication.reload.used_at
  end
end
