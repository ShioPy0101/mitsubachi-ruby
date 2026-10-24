require "test_helper"

class EmailIdentities::DigestTest < ActiveSupport::TestCase
  test "uses keyed SHA256 after Devise compatible normalization" do
    with_key("a" * 32) do
      expected = OpenSSL::HMAC.hexdigest("SHA256", "a" * 32, "test@example.com")
      assert_equal expected, EmailIdentities::Digest.call("  Test@Example.COM  ")
      refute_equal Digest::SHA256.hexdigest("test@example.com"), expected
      refute_equal EmailIdentities::Digest.call("test+tag@example.com"), expected
    end
  end

  test "changing the dedicated key changes the digest and fingerprint" do
    first = with_key("a" * 32) { [ EmailIdentities::Digest.call("test@example.com"), EmailIdentities::Digest.fingerprint ] }
    second = with_key("b" * 32) { [ EmailIdentities::Digest.call("test@example.com"), EmailIdentities::Digest.fingerprint ] }
    refute_equal first.first, second.first
    refute_equal first.last, second.last
  end

  test "refuses a short configured key instead of falling back to secret key base" do
    with_key("short") do
      assert_raises(EmailIdentities::Digest::ConfigurationError) { EmailIdentities::Digest.call("test@example.com") }
    end
  end

  private

  def with_key(value)
    previous = ENV["EMAIL_IDENTITY_HMAC_KEY"]
    ENV["EMAIL_IDENTITY_HMAC_KEY"] = value
    yield
  ensure
    ENV["EMAIL_IDENTITY_HMAC_KEY"] = previous
  end
end
