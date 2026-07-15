class RenameAdminAuditLogChanges < ActiveRecord::Migration[8.1]
  def change
    rename_column :admin_audit_logs, :changes, :change_set
  end
end
