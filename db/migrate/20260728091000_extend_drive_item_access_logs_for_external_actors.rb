class ExtendDriveItemAccessLogsForExternalActors < ActiveRecord::Migration[8.1]
  def up
    change_column_null :drive_item_access_logs, :user_id, true
    add_column :drive_item_access_logs, :actor_kind, :string, null: false, default: "user"
    add_reference :drive_item_access_logs,
                  :external_share,
                  foreign_key: { on_delete: :nullify },
                  index: true
    add_index :drive_item_access_logs, [ :actor_kind, :occurred_at ]
    add_index :drive_item_access_logs, [ :request_id, :action ]
  end

  def down
    remove_index :drive_item_access_logs, [ :request_id, :action ]
    remove_index :drive_item_access_logs, [ :actor_kind, :occurred_at ]
    remove_reference :drive_item_access_logs, :external_share, foreign_key: true
    remove_column :drive_item_access_logs, :actor_kind
    change_column_null :drive_item_access_logs, :user_id, false
  end
end
