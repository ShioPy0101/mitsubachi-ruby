require "test_helper"

class Deployment::MigrationVerifierTest < ActiveSupport::TestCase
  test "有効なメール認証待ちユーザーはmembership不整合として扱わない" do
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
    authentication = EmailAuthentication.create!(
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

    authentication.update!(expires_at: 1.minute.ago)
    expired_report = Deployment::MigrationVerifier.new.call
    refute expired_report[:valid]
    assert_equal 1, expired_report[:users_without_membership]
    assert_equal 1, expired_report[:organization_mismatches]
  end
end
