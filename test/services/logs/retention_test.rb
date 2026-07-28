require "test_helper"

class Logs::RetentionTest < ActiveSupport::TestCase
  test "設定された種類だけをバッチ削除して完了イベントを残す" do
    organization = organizations(:one)
    old_operation = OperationLog.create!(
      actor_kind: "anonymous", organization: organization, operation_type: "auth.verification_failed",
      result: "denied", occurred_at: 40.days.ago
    )
    kept_operation = OperationLog.create!(
      actor_kind: "anonymous", organization: organization, operation_type: "auth.verification_failed",
      result: "denied", occurred_at: 2.days.ago
    )
    old_event = SystemEvent.create!(
      event_type: "storage.file_missing", severity: "error", source: "storage", occurred_at: 40.days.ago
    )

    result = Logs::Retention.new(
      retention_days: { operation_logs: 30, drive_item_access_logs: nil, system_info: nil,
                        system_warning: nil, system_error: 30, system_critical: nil },
      batch_size: 1
    ).call

    assert_not OperationLog.exists?(old_operation.id)
    assert OperationLog.exists?(kept_operation.id)
    assert_not SystemEvent.exists?(old_event.id)
    assert_equal 1, result[:operation_logs]
    assert_equal 1, result[:system_error]
    assert SystemEvent.exists?(event_type: "maintenance.log_retention_completed")
  end
end
