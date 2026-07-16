require "test_helper"

class OrganizationTest < ActiveSupport::TestCase
  test "name is required" do
    organization = Organization.new(name: "")

    assert_not organization.valid?
    assert_includes organization.errors[:name], "can't be blank"
  end
end
