require "test_helper"

class Security::RateLimiterTest < ActiveSupport::TestCase
  setup do
    Rails.cache.clear
  end

  test "allows requests until the limit is exceeded" do
    limiter = -> { Security::RateLimiter.new(namespace: "test", key: "client", limit: 2, period: 1.minute).call }

    assert limiter.call.allowed?
    assert limiter.call.allowed?
    assert_not limiter.call.allowed?
    assert_equal 60, limiter.call.retry_after
  end
end
