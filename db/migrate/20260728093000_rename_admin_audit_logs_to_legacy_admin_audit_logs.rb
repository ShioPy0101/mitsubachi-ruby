class RenameAdminAuditLogsToLegacyAdminAuditLogs < ActiveRecord::Migration[8.1]
  def change
    rename_table :admin_audit_logs, :legacy_admin_audit_logs
  end
end
