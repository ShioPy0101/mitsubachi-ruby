class AddIndexesToDriveItemAccessLogs < ActiveRecord::Migration[8.1]
  def change
    add_index :drive_item_access_logs,
              [:drive_item_id, :accessed_at],
              name: "index_access_logs_on_item_and_accessed_at"

    add_index :drive_item_access_logs,
              [:user_id, :accessed_at],
              name: "index_access_logs_on_user_and_accessed_at"
  end
end