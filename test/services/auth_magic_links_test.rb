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

    result = Auth::MagicLinks.new.request_login(email: email_for(user))

    expected_organizations = [ organizations(:one), second_organization ].sort_by(&:id)
    assert_equal expected_organizations, result.organizations
    assert_equal expected_organizations.first, result.organization
  end
  test "email change reauthentication requires a new login link and keeps recipient encrypted" do
    result = Auth::MagicLinks.new.request_login(email: " TEST1@example.com ", intent: "email_change")
    authentication = result.authentication.reload
    assert authentication.email_change_reauthentication?
    assert_nil authentication.email
    refute_includes authentication.attributes.to_json, "test1@example.com"
    assert_equal "test1@example.com", EmailIdentities::DeliveryPayload.decrypt(authentication.recipient_ciphertext, purpose: "email_change_reauthentication")
    verified = Auth::MagicLinks.new.verify(result.token)
    assert_equal users(:one).id, verified.user.id
    assert_equal authentication.id, verified.authentication.id
    assert_raises(Auth::MagicLinks::Failure) { Auth::MagicLinks.new.verify(result.token) }
  end
end
