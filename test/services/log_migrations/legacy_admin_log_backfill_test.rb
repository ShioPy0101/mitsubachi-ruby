require "test_helper"

class LogMigrations::LegacyAdminLogBackfillTest < ActiveSupport::TestCase
  test "対応するOperationLogがないlegacy recordだけを冪等に移行する" do
    unique = LegacyAdminAuditLog.create!(
      actor_user: users(:one),
      organization: organizations(:one),
      action: "user.suspend",
      target_type: "User",
      target_id: users(:two).id,
      change_set: { suspended_at: [ nil, Time.current ] },
      created_at: 2.hours.ago,
      updated_at: 2.hours.ago
    )
    duplicate = LegacyAdminAuditLog.create!(
      actor_user: users(:one),
      organization: organizations(:one),
      action: "drive_item.delete",
      target_type: "DriveItem",
      target_id: drive_items(:child_file).id,
      created_at: 1.hour.ago,
      updated_at: 1.hour.ago
    )
    OperationLog.create!(
      actor_kind: "user",
      actor_user: duplicate.actor_user,
      organization: duplicate.organization,
      operation_type: "drive_item.deleted",
      result: "success",
      target_type: duplicate.target_type,
      target_id: duplicate.target_id,
      occurred_at: duplicate.created_at
    )

    first = LogMigrations::LegacyAdminLogBackfill.new(batch_size: 1).call
    second = LogMigrations::LegacyAdminLogBackfill.new(batch_size: 1).call

    migrated = OperationLog.find_by("metadata ->> 'legacy_admin_audit_log_id' = ?", unique.id.to_s)
    assert migrated
    assert_equal "user.suspended", migrated.operation_type
    assert_operator first.inserted_count, :>=, 1
    assert_operator first.deduplicated_count, :>=, 1
    assert_equal 0, second.inserted_count
    assert_equal first.processed_count, second.deduplicated_count
  end
end
