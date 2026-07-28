class RenameAuditEventsToOperationLogs < ActiveRecord::Migration[8.1]
  def change
    rename_table :audit_events, :operation_logs
    rename_column :operation_logs, :action, :operation_type
    rename_column :operation_logs, :outcome, :result

    add_column :operation_logs, :actor_kind, :string, null: false, default: "anonymous"
    add_reference :operation_logs,
                  :actor_external_share,
                  foreign_key: { to_table: :external_shares, on_delete: :nullify },
                  index: true
    add_index :operation_logs, [ :actor_kind, :occurred_at ]
  end
end
