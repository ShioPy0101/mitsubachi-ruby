require "test_helper"

class EmailAuthenticationsControllerTest < ActionDispatch::IntegrationTest
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

    assert_no_difference "EmailAuthentication.count" do
      post api_v1_auth_login_url, params: { email: "pending@example.com" }
    end

    assert_response :unauthorized
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
      post api_v1_auth_create_url, params: {
        email: " stale@example.com ",
        invite_code: "fresh-invite"
      }
    end

    assert_response :ok
    assert_equal organizations(:two), user.reload.organization
    assert_nil stale_invite.reload.stand_by_user
    assert_equal user, invite.reload.stand_by_user
    assert invite.stand_by_at.present?
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
end
