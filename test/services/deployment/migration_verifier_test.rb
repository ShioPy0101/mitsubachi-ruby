require "test_helper"

class Deployment::MigrationVerifierTest < ActiveSupport::TestCase
  test "未使用inviteのメール認証待ちユーザーはmembership不整合として扱わない" do
    organization = organizations(:one)
    user = User.create!(
      organization:,
      email: "pending-deployment-verification@example.com",
      password: SecureRandom.base64(32)
    )
    invite = OrganizationInvite.create!(
      organization:,
      code: SecureRandom.hex(16),
      expires_at: 1.hour.from_now,
      stand_by_at: Time.current,
      stand_by_user: user
    )
    EmailAuthentication.create!(
      organization_invite: invite,
      email: user.email,
      token: SecureRandom.hex(32),
      purpose: "registration",
      expires_at: 15.minutes.from_now
    )

    report = Deployment::MigrationVerifier.new.call
    assert report[:valid]
    assert_equal 1, report[:pending_registration_users]
    assert_equal 0, report[:users_without_membership]
    assert_equal 0, report[:organization_mismatches]

    invite.update!(stand_by_user: nil, stand_by_at: nil)
    joined_user_report = Deployment::MigrationVerifier.new.call
    refute joined_user_report[:valid]
    assert_equal 1, joined_user_report[:users_without_membership]
    assert_equal 1, joined_user_report[:organization_mismatches]
  end
end
