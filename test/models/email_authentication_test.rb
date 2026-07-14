require "test_helper"

class EmailAuthenticationTest < ActiveSupport::TestCase
  test "requires email token and expires_at" do
    authentication = EmailAuthentication.new

    assert_not authentication.valid?
    assert_includes authentication.errors[:email], "can't be blank"
    assert_includes authentication.errors[:token], "can't be blank"
    assert_includes authentication.errors[:expires_at], "can't be blank"
  end

  test "requires unique token" do
    authentication = EmailAuthentication.new(
      email: "another@example.com",
      token: email_authentications(:one).token,
      expires_at: 1.hour.from_now
    )

    assert_not authentication.valid?
    assert_includes authentication.errors[:token], "has already been taken"
  end
end
