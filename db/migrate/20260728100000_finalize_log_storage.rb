class FinalizeLogStorage < ActiveRecord::Migration[8.0]
  ACTOR_CHECK = <<~SQL.squish
    (actor_kind = 'user' AND actor_user_id IS NOT NULL AND actor_external_share_id IS NULL) OR
    (actor_kind = 'external_share' AND actor_user_id IS NULL AND actor_external_share_id IS NOT NULL) OR
    (actor_kind = 'anonymous' AND actor_user_id IS NULL AND actor_external_share_id IS NULL)
  SQL
  ACCESS_ACTOR_CHECK = <<~SQL.squish
    (actor_kind = 'user' AND user_id IS NOT NULL AND external_share_id IS NULL) OR
    (actor_kind = 'external_share' AND user_id IS NULL) OR
    (actor_kind = 'anonymous' AND user_id IS NULL AND external_share_id IS NULL)
  SQL

  def up
    add_column :drive_item_access_logs, :batch_id, :string
    add_index :drive_item_access_logs, :batch_id
    normalize_existing_operation_log_actors!
    add_check_constraint :operation_logs, ACTOR_CHECK, name: "operation_logs_actor_consistency"
    add_check_constraint :drive_item_access_logs, ACCESS_ACTOR_CHECK, name: "drive_item_access_logs_actor_consistency"
    migrate_legacy_admin_logs!
    drop_table :legacy_admin_audit_logs
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "legacy data restoration requires the documented backup procedure"
  end

  private

  # actor_kind追加前から存在するuser操作ログにはdefaultのanonymousが入るため、制約追加前に正規化する。
  def normalize_existing_operation_log_actors!
    ambiguous_count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM operation_logs
      WHERE actor_user_id IS NOT NULL AND actor_external_share_id IS NOT NULL
    SQL
    if ambiguous_count.positive?
      raise ActiveRecord::MigrationError,
            "operation_logs contains #{ambiguous_count} rows with both user and external-share actors"
    end

    execute <<~SQL.squish
      UPDATE operation_logs
      SET actor_kind = CASE
        WHEN actor_user_id IS NOT NULL THEN 'user'
        WHEN actor_external_share_id IS NOT NULL THEN 'external_share'
        ELSE 'anonymous'
      END
    SQL
  end

  # drop前に全行を既存行または新規行へ対応付け、欠損時はmigration自体を中止する。
  def migrate_legacy_admin_logs!
    return unless table_exists?(:legacy_admin_audit_logs)

    legacy = Class.new(ActiveRecord::Base) { self.table_name = "legacy_admin_audit_logs" }
    operation = Class.new(ActiveRecord::Base) { self.table_name = "operation_logs" }
    report = Hash.new(0)

    legacy.in_batches(of: 500) do |batch|
      batch.each do |row|
        report[:source_count] += 1
        mapped_type = operation_type_map.fetch(row.action, row.action)
        duplicate = operation.where(
          actor_user_id: row.actor_user_id, organization_id: row.organization_id,
          operation_type: mapped_type, target_type: row.target_type, target_id: row.target_id,
          occurred_at: (row.created_at - 5.seconds)..(row.created_at + 5.seconds)
        ).exists?
        if duplicate
          report[:duplicate_count] += 1
          next
        end

        operation.create!(
          actor_kind: row.actor_user_id.present? ? "user" : "anonymous",
          actor_user_id: row.actor_user_id,
          organization_id: row.organization_id,
          operation_type: mapped_type,
          result: "success",
          target_type: row.target_type,
          target_id: row.target_id,
          change_set: row.change_set || {},
          metadata: { legacy_source_id: row.id, legacy_source: "admin_operation" },
          ip_address: row.ip_address,
          user_agent: row.user_agent,
          occurred_at: row.created_at,
          created_at: row.created_at,
          updated_at: row.updated_at
        )
        report[:migrated_count] += 1
        report[:actor_unresolved_count] += 1 if row.actor_user_id.nil?
        report[:target_unresolved_count] += 1 if row.target_type.blank? || row.target_id.nil?
      end
    end

    report[:unmigrated_count] = report[:source_count] - report[:migrated_count] - report[:duplicate_count]
    say "legacy admin operation migration: #{report.sort.to_h.to_json}"
    raise ActiveRecord::MigrationError, "legacy admin operation logs remain unmigrated" unless report[:unmigrated_count].zero?
  end

  def operation_type_map
    {
      "organization.create" => "organization.created",
      "organization.update" => "organization.settings_updated",
      "user.suspend" => "user.suspended",
      "user.unsuspend" => "user.unsuspended",
      "drive_item.delete" => "drive_item.deleted",
      "drive_item.restore" => "drive_item.restored",
      "drive_item.purge" => "drive_item.purged"
    }
  end
end
