require "test_helper"

class EmailAuthenticationsControllerTest < ActionDispatch::IntegrationTest
  test "should require params for create" do
    post auth_create_url
    assert_response :bad_request
  end

  test "should require params for verify" do
    post auth_verify_url
    assert_response :bad_request
  end
end
