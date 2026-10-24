require "test_helper"

class EmailIdentities::DeliveryPayloadTest < ActiveSupport::TestCase
  test "recipient envelope is authenticated purpose bound and expires" do
    payload = EmailIdentities::DeliveryPayload.encrypt("private@example.com", purpose: "magic_link", expires_at: 1.minute.from_now)
    refute_includes payload, "private@example.com"
    assert_equal "private@example.com", EmailIdentities::DeliveryPayload.decrypt(payload, purpose: "magic_link")
    assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
      EmailIdentities::DeliveryPayload.decrypt(payload, purpose: "email_change")
    end
    travel 2.minutes do
      assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
        EmailIdentities::DeliveryPayload.decrypt(payload, purpose: "magic_link")
      end
    end
    assert_raises(ActiveSupport::MessageEncryptor::InvalidMessage) do
      EmailIdentities::DeliveryPayload.decrypt(payload.reverse, purpose: "magic_link")
    end
  end
end
