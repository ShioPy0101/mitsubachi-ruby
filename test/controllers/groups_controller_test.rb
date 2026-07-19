require "test_helper"

class GroupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @organization = organizations(:one)
  end

  test "member can view own group without member emails" do
    sign_in @user

    get api_v1_group_url

    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal @organization.name, data.fetch("name")
    assert_equal @organization.description, data.fetch("description")
    members = data.fetch("members")
    assert_includes members.pluck("display_name"), "User One"
    assert_not_includes response.body, @user.email
    assert_not_includes response.body, users(:two).display_name
  end

  test "member cannot update group" do
    sign_in @user

    patch api_v1_group_url, params: { group: { name: "New group" } }

    assert_response :forbidden
    assert_equal @organization.name, @organization.reload.name
  end

  test "organization admin can update group and audit event is recorded" do
    @user.update!(role: :organization_admin)
    sign_in @user

    assert_difference "AuditEvent.where(action: 'group.update').count", 1 do
      patch api_v1_group_url, params: { group: { name: "New group", description: "Updated" } }
    end

    assert_response :ok
    assert_equal "New group", @organization.reload.name
    assert_equal "Updated", @organization.description
  end
end
