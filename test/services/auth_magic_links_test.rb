require "test_helper"

class Auth::MagicLinksTest < ActiveSupport::TestCase
  test "login request returns every active organization in stable order" do
    user = users(:one)
    second_organization = organizations(:two)
    excluded_organization = Organization.create!(name: "Suspended Organization")
    user.organization_memberships.create!(
      organization: second_organization,
      role: :member,
      status: :active
    )
    user.organization_memberships.create!(
      organization: excluded_organization,
      role: :member,
      status: :suspended
    )

    result = Auth::MagicLinks.new.request_login(email: user.email)

    expected_organizations = [ organizations(:one), second_organization ].sort_by(&:id)
    assert_equal expected_organizations, result.organizations
    assert_equal expected_organizations.first, result.organization
  end
end
