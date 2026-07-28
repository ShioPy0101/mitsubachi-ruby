class CreateSystemEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :system_events do |t|
      t.string :event_type, null: false
      t.string :severity, null: false
      t.string :source, null: false
      t.references :organization, foreign_key: true
      t.references :related_user, foreign_key: { to_table: :users }
      t.string :target_type
      t.bigint :target_id
      t.string :request_id
      t.string :job_id
      t.string :trace_id
      t.string :error_class
      t.text :error_message
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :system_events, [ :event_type, :occurred_at ]
    add_index :system_events, [ :severity, :occurred_at ]
    add_index :system_events, [ :source, :occurred_at ]
    add_index :system_events, [ :organization_id, :occurred_at ]
    add_index :system_events, :request_id
    add_index :system_events, :job_id
    add_index :system_events, :trace_id
    add_index :system_events, [ :target_type, :target_id ]
  end
end
