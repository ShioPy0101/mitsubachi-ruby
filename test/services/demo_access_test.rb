require "test_helper"

class DemoAccessTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "issues a demo email without delivering mail and verifies only once" do
    assert_no_difference [ "User.count", "Organization.count", "EmailAuthentication.count" ] do
      mail = Demo::Access.issue
      assert_equal "demo@tenant.example", mail[:to]
      assert_includes mail[:body], mail[:url]
      assert_includes mail[:url], "https://demo.mitsubachi.shiosalt.com/demo/verify?"
      token = Rack::Utils.parse_query(URI(mail[:url]).query).fetch("token")
      session_token = Demo::Access.verify(token)
      assert Demo::Access.authenticated?(session_token)
      assert_not Demo::Access.authenticated?(token)
      assert_raises(Demo::Access::InvalidLink) { Demo::Access.verify(token) }
      travel 9.hours
      assert_not Demo::Access.authenticated?(session_token)
    end
  end

  test "rejects invalid and expired links" do
    assert_raises(Demo::Access::InvalidLink) { Demo::Access.verify("invalid") }
    token = Rack::Utils.parse_query(URI(Demo::Access.issue[:url]).query).fetch("token")
    travel 16.minutes
    assert_raises(Demo::Access::InvalidLink) { Demo::Access.verify(token) }
  end
end
