require "test_helper"

class LogMigrations::OperationLogBackfillTest < ActiveSupport::TestCase
  test "legacy operation type and user actor are backfilled idempotently" do
    log = OperationLog.create!(
      actor_kind: "user",
      actor_user: users(:one),
      organization: organizations(:one),
      operation_type: "drive_item.delete",
      result: "success",
      occurred_at: Time.current
    )
    log.update_columns(actor_kind: "anonymous")

    first = LogMigrations::OperationLogBackfill.new(batch_size: 1).call
    second = LogMigrations::OperationLogBackfill.new(batch_size: 1).call

    assert_operator first.updated_count, :>=, 1
    assert_equal "drive_item.deleted", log.reload.operation_type
    assert_equal "user", log.actor_kind
    assert_equal 0, second.updated_count
  end
end
