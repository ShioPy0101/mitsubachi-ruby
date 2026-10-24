require "test_helper"

class Deployment::SmokeTestCredentialsTest < ActiveSupport::TestCase
  test "三権限とorganization切り替え用の短寿命認証情報を冪等に準備する" do
    first = Deployment::SmokeTestCredentials.new.call
    second = Deployment::SmokeTestCredentials.new.call

    assert_equal %i[member organization_admin system_admin], first.fetch(:users).keys
    assert_equal first.dig(:organizations, :primary_id), second.dig(:organizations, :primary_id)
    digests = first.fetch(:users).values.map { |entry| EmailIdentities::Digest.call(entry.fetch(:email)) }
    assert_equal 2, User.where(email_digest: digests).where.not(role: :system_admin).count
    assert_equal 1, User.system_admin.where(email_digest: digests).count

    member = User.with_email(first.dig(:users, :member, :email)).first!
    assert_equal 2, member.organization_memberships.active.count
    assert Auth::MagicLinks.new.verify(second.dig(:users, :member, :token), expected_purpose: "login").user == member
    assert_raises(Auth::MagicLinks::Failure) do
      Auth::MagicLinks.new.verify(second.dig(:users, :member, :token), expected_purpose: "login")
    end
  end
end
