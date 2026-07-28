require "test_helper"

class OperationLogTest < ActiveSupport::TestCase
  test "user actor requires actor_user" do
    log = OperationLog.new(
      actor_kind: "user",
      operation_type: "drive_item.created",
      result: "success",
      occurred_at: Time.current
    )

    assert_not log.valid?
    assert_includes log.errors[:actor_user], "を指定してください"
  end

  test "anonymous actor has no related actor ids" do
    log = OperationLog.new(
      actor_kind: "anonymous",
      operation_type: "auth.verification_failed",
      result: "denied",
      occurred_at: Time.current
    )

    assert log.valid?
  end
end
