require "test_helper"

class OrganizationInviteTest < ActiveSupport::TestCase
  test "code and expires_at are required" do
    invite = OrganizationInvite.new(organization: organizations(:one))

    assert_not invite.valid?
    assert_includes invite.errors[:code], "can't be blank"
    assert_includes invite.errors[:expires_at], "can't be blank"
  end
end
