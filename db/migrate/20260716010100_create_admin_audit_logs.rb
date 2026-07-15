class CreateAdminAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_audit_logs do |t|
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.references :organization, null: false, foreign_key: true
      t.string :action, null: false
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.jsonb :changes, null: false, default: {}
      t.string :ip_address
      t.text :user_agent

      t.timestamps
    end

    add_index :admin_audit_logs, :action
    add_index :admin_audit_logs, [ :target_type, :target_id ]
    add_index :admin_audit_logs, :created_at
  end
end
