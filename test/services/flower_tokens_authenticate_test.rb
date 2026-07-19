require "test_helper"

class FlowerTokensAuthenticateTest < ActiveSupport::TestCase
  test "authenticates valid bearer token by digest" do
    raw_token = "service-token"
    access_token = FlowerAccessToken.create!(
      user: users(:one),
      organization: organizations(:one),
      access_token_digest: Flower::Tokens::Codec.digest(raw_token),
      scopes: [ "flower:read" ],
      expires_at: 15.minutes.from_now
    )

    result = Flower::Tokens::Authenticate.new(raw_token: raw_token, required_scopes: [ "flower:read" ]).call

    assert result.success?
    assert_equal access_token, result.token
  end

  test "rejects expired revoked and insufficient scope tokens" do
    expired = create_token("expired", expires_at: 1.minute.ago)
    assert_equal "invalid_token", Flower::Tokens::Authenticate.new(raw_token: "expired").call.error_code

    revoked = create_token("revoked", revoked_at: Time.current)
    assert_equal "invalid_token", Flower::Tokens::Authenticate.new(raw_token: "revoked").call.error_code

    read_only = create_token("read-only", scopes: [ "flower:read" ])
    result = Flower::Tokens::Authenticate.new(raw_token: "read-only", required_scopes: [ "flower:download" ]).call
    assert_equal "insufficient_scope", result.error_code

    assert expired
    assert revoked
    assert read_only
  end

  private

  def create_token(raw_token, scopes: [ "flower:read" ], expires_at: 15.minutes.from_now, revoked_at: nil)
    FlowerAccessToken.create!(
      user: users(:one),
      organization: organizations(:one),
      access_token_digest: Flower::Tokens::Codec.digest(raw_token),
      scopes: scopes,
      expires_at: expires_at,
      revoked_at: revoked_at
    )
  end
end
