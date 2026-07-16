require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  test "action and occurred_at are required" do
    event = AuditEvent.new(outcome: "success")

    assert_not event.valid?
    assert_includes event.errors[:action], "can't be blank"
    assert_includes event.errors[:occurred_at], "can't be blank"
  end

  test "outcome must be known" do
    event = AuditEvent.new(action: "test.event", outcome: "unknown", occurred_at: Time.current)

    assert_not event.valid?
    assert_includes event.errors[:outcome], "is not included in the list"
  end
end
