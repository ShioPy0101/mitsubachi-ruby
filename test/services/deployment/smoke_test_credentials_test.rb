require "test_helper"

class Deployment::SmokeTestCredentialsTest < ActiveSupport::TestCase
  test "三権限とorganization切り替え用の短寿命認証情報を冪等に準備する" do
    first = Deployment::SmokeTestCredentials.new.call
    second = Deployment::SmokeTestCredentials.new.call

    assert_equal %i[member organization_admin system_admin], first.fetch(:users).keys
    assert_equal first.dig(:organizations, :primary_id), second.dig(:organizations, :primary_id)
    assert_equal 2, User.where("email LIKE ?", "mitsubachi-smoke-%@example.invalid").where.not(role: :system_admin).count
    assert_equal 1, User.system_admin.where("email LIKE ?", "mitsubachi-smoke-%@example.invalid").count

    member = User.find_by!(email: first.dig(:users, :member, :email))
    assert_equal 2, member.organization_memberships.active.count
    assert Auth::MagicLinks.new.verify(first.dig(:users, :member, :token), expected_purpose: "login").user == member
    assert_raises(Auth::MagicLinks::Failure) do
      Auth::MagicLinks.new.verify(first.dig(:users, :member, :token), expected_purpose: "login")
    end
  end
end
