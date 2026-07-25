require "test_helper"

class OrganizationInvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @organization = organizations(:two)
    @invite = OrganizationInvite.create!(
      organization: @organization,
      code: "join-token",
      email: @user.email,
      role: :organization_admin,
      expires_at: 1.day.from_now,
      invited_by_user: users(:two)
    )
  end

  test "shows minimum invitation details without login" do
    get api_v1_organization_invitation_url(@invite.code)

    assert_response :ok
    invitation = response.parsed_body.fetch("invitation")
    assert_equal @invite.code, invitation.fetch("token")
    assert_equal @organization.name, invitation.dig("organization", "name")
    assert_equal @user.email, invitation.fetch("email")
    assert_equal "organization_admin", invitation.fetch("role")
    assert_equal users(:two).email, invitation.dig("invited_by", "email")
  end

  test "logged in existing user can join another organization" do
    sign_in @user

    assert_difference "@user.organization_memberships.count", 1 do
      post api_v1_accept_organization_invitation_url(@invite.code)
    end

    assert_response :ok
    membership = @user.organization_memberships.find_by!(organization: @organization)
    assert membership.organization_admin?
    assert membership.active?
    assert_equal @user, @invite.reload.used_by_user
    assert @invite.used_at.present?
    assert_equal "組織に参加しました", response.parsed_body.fetch("message")
  end

  test "joining another organization keeps existing memberships" do
    sign_in @user

    post api_v1_accept_organization_invitation_url(@invite.code)

    assert_response :ok
    assert @user.organization_memberships.exists?(organization: organizations(:one))
    assert @user.organization_memberships.exists?(organization: @organization)
  end

  test "already member does not create duplicate membership" do
    @user.organization_memberships.create!(
      organization: @organization,
      role: :member,
      status: :active
    )
    sign_in @user

    assert_no_difference "@user.organization_memberships.count" do
      post api_v1_accept_organization_invitation_url(@invite.code)
    end

    assert_response :conflict
    assert_api_error :already_member, "既にこの組織に所属しています"
  end

  test "rejects email mismatch" do
    sign_in users(:two)

    assert_no_difference "OrganizationMembership.count" do
      post api_v1_accept_organization_invitation_url(@invite.code)
    end

    assert_response :forbidden
    assert_api_error :email_mismatch, "招待先メールアドレスとログイン中のアカウントが一致しません"
  end

  test "rejects expired invitation" do
    @invite.update!(expires_at: 1.minute.ago)
    sign_in @user

    post api_v1_accept_organization_invitation_url(@invite.code)

    assert_response :unauthorized
    assert_api_error :invitation_expired, "招待リンクの有効期限が切れています"
  end

  test "rejects revoked invitation" do
    @invite.update!(revoked_at: Time.current)
    sign_in @user

    post api_v1_accept_organization_invitation_url(@invite.code)

    assert_response :gone
    assert_api_error :invitation_revoked, "招待は取り消されています"
  end

  test "rejects accepted invitation" do
    @invite.update!(used_at: Time.current, used_by_user: @user)
    sign_in @user

    post api_v1_accept_organization_invitation_url(@invite.code)

    assert_response :conflict
    assert_api_error :invitation_already_accepted, "招待は既に承諾されています"
  end

  test "requires login to accept invitation" do
    post api_v1_accept_organization_invitation_url(@invite.code)

    assert_response :unauthorized
  end

  test "accepting invitation does not require registration magic link for verified user" do
    sign_in @user

    assert_no_difference "EmailAuthentication.where(purpose: 'registration').count" do
      post api_v1_accept_organization_invitation_url(@invite.code)
    end

    assert_response :ok
    refute_equal "登録用リンクでメール認証を完了してください", response.parsed_body.dig("error", "message")
  end

  test "second accept request cannot create duplicate membership" do
    sign_in @user

    post api_v1_accept_organization_invitation_url(@invite.code)
    assert_response :ok

    sign_in @user
    assert_no_difference "@user.organization_memberships.count" do
      post api_v1_accept_organization_invitation_url(@invite.code)
    end

    assert_response :conflict
    assert_api_error :invitation_already_accepted, "招待は既に承諾されています"
  end

  private

  def assert_api_error(code, message)
    error = response.parsed_body.fetch("error")
    assert_equal code.to_s, error.fetch("code")
    assert_equal message, error.fetch("message")
  end
end
