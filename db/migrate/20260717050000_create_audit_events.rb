class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_events do |t|
      t.references :organization, foreign_key: true
      t.references :actor_user, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.string :outcome, null: false, default: "success"
      t.string :target_type
      t.bigint :target_id
      t.jsonb :change_set, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.string :ip_address
      t.text :user_agent
      t.string :request_id
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :audit_events, :action
    add_index :audit_events, :occurred_at
    add_index :audit_events, [ :target_type, :target_id ]
    add_index :audit_events, [ :organization_id, :occurred_at ]
    add_index :audit_events, [ :actor_user_id, :occurred_at ]
  end
end
