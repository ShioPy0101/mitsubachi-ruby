require "test_helper"

class EmailAuthenticationsControllerTest < ActionDispatch::IntegrationTest
  test "should get new" do
    get email_authentications_new_url
    assert_response :success
  end

  test "should get verify_form" do
    get email_authentications_verify_form_url
    assert_response :success
  end
end
