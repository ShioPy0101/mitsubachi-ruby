require "test_helper"

class EmailAuthenticationTest < ActiveSupport::TestCase
  test "requires email token expires_at and purpose" do
    authentication = EmailAuthentication.new(purpose: nil)

    assert_not authentication.valid?
    assert_includes authentication.errors[:email], "can't be blank"
    assert_includes authentication.errors[:token], "can't be blank"
    assert_includes authentication.errors[:expires_at], "can't be blank"
    assert_includes authentication.errors[:purpose], "can't be blank"
  end

  test "requires supported purpose" do
    authentication = EmailAuthentication.new(
      email: "purpose@example.com",
      token: "purpose-token",
      expires_at: 1.hour.from_now,
      purpose: "password_reset"
    )

    assert_not authentication.valid?
    assert_includes authentication.errors[:purpose], "is not included in the list"
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

  test "stores delivery token encrypted separately from hashed token" do
    raw_token = "raw-delivery-token"
    authentication = EmailAuthentication.create!(
      email: "delivery-token@example.com",
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 1.hour.from_now,
      purpose: "login",
      delivery_token: raw_token
    )

    assert_equal raw_token, authentication.delivery_token
    assert_not_equal raw_token, authentication.delivery_token_ciphertext
    assert_equal Digest::SHA256.hexdigest(raw_token), authentication.token
  end
end
