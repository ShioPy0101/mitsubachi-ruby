require "test_helper"

class FlowerAccessTokenTest < ActiveSupport::TestCase
  test "token user must belong to organization" do
    token = FlowerAccessToken.new(
      user: users(:one),
      organization: organizations(:two),
      access_token_digest: "digest",
      scopes: [ "flower:read" ],
      expires_at: 15.minutes.from_now
    )

    assert_not token.valid?
  end

  test "active reflects expiration and revocation" do
    token = FlowerAccessToken.new(expires_at: 15.minutes.from_now)
    assert token.active?

    token.revoked_at = Time.current
    assert_not token.active?
  end
end
