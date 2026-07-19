require "test_helper"

class FlowerDeviceAuthorizationTest < ActiveSupport::TestCase
  test "normalizes user code digest" do
    assert_equal(
      Flower::DeviceAuthorizations::Code.user_code_digest("ABCD-EFGH"),
      Flower::DeviceAuthorizations::Code.user_code_digest("abcd efgh")
    )
  end

  test "approved authorization requires user and organization" do
    authorization = FlowerDeviceAuthorization.new(
      device_code_digest: "device",
      user_code_digest: "user",
      status: "approved",
      expires_at: 10.minutes.from_now
    )

    assert_not authorization.valid?
  end
end
