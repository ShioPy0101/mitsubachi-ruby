require "test_helper"

class OrganizationMembershipTest < ActiveSupport::TestCase
  test "1ユーザーが複数organizationに所属できる" do
    membership = users(:one).organization_memberships.create!(
      organization: organizations(:two),
      role: :member,
      status: :active
    )

    assert_equal organizations(:two), membership.organization
    assert_includes users(:one).organizations, organizations(:two)
  end

  test "organizationごとに異なるroleを保持できる" do
    user = users(:one)
    user.active_membership_for(organizations(:one)).update!(role: :organization_admin)
    user.organization_memberships.create!(
      organization: organizations(:two),
      role: :member,
      status: :active
    )

    assert user.active_membership_for(organizations(:one)).organization_admin?
    assert user.active_membership_for(organizations(:two)).member?
  end

  test "同一organizationへの重複membershipを作成できない" do
    duplicate = users(:one).organization_memberships.build(
      organization: organizations(:one),
      role: :member,
      status: :active
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "membershipを削除しても他organization所属へ影響しない" do
    user = users(:one)
    extra = user.organization_memberships.create!(
      organization: organizations(:two),
      role: :member,
      status: :active
    )

    assert_difference "user.organization_memberships.count", -1 do
      extra.destroy!
    end

    assert user.organization_memberships.exists?(organization: organizations(:one))
  end
end
