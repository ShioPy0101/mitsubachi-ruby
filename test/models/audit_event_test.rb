require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  test "operation_type and occurred_at are required" do
    event = OperationLog.new(actor_kind: "anonymous", result: "success")

    assert_not event.valid?
    assert_includes event.errors[:operation_type], "can't be blank"
    assert_includes event.errors[:occurred_at], "can't be blank"
  end

  test "result must be known" do
    event = OperationLog.new(
      actor_kind: "anonymous", operation_type: "test.event", result: "unknown", occurred_at: Time.current
    )

    assert_not event.valid?
    assert_includes event.errors[:result], "is not included in the list"
  end
end
