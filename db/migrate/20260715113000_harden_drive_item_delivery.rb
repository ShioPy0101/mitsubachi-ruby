class HardenDriveItemDelivery < ActiveRecord::Migration[8.1]
  def up
    add_column :drive_items, :file_size, :bigint
    add_column :drive_items, :content_type, :string

    rename_column :drive_item_access_logs, :accessed_at, :occurred_at
    add_column :drive_item_access_logs, :ip_address, :string
    add_column :drive_item_access_logs, :user_agent, :text
    add_column :drive_item_access_logs, :request_id, :string
    add_column :drive_item_access_logs, :metadata, :jsonb, default: {}, null: false

    change_column_null :drive_item_access_logs, :drive_item_id, true

    remove_foreign_key :drive_item_access_logs, :drive_items
    add_foreign_key :drive_item_access_logs, :drive_items, on_delete: :nullify

    execute <<~SQL
      UPDATE drive_items
      SET storage_key = NULLIF(regexp_replace(COALESCE(storage_key, blob_path), '^drive_items/', ''), '')
    SQL

    execute <<~SQL
      UPDATE drive_items
      SET blob_path = CASE
        WHEN storage_key IS NULL THEN NULL
        ELSE 'drive_items/' || storage_key
      END
    SQL

    execute <<~SQL
      UPDATE drive_item_access_logs
      SET
        ip_address = COALESCE(ip_address, '0.0.0.0'),
        request_id = COALESCE(request_id, 'backfilled-request-id'),
        metadata = COALESCE(metadata, '{}'::jsonb)
    SQL

    change_column_null :drive_item_access_logs, :ip_address, false
    change_column_null :drive_item_access_logs, :request_id, false

    add_index :drive_item_access_logs,
              [ :organization_id, :user_id, :drive_item_id, :action, :occurred_at ],
              name: "index_drive_item_access_logs_on_stream_dedupe_lookup"
  end

  def down
    remove_index :drive_item_access_logs, name: "index_drive_item_access_logs_on_stream_dedupe_lookup"

    remove_foreign_key :drive_item_access_logs, :drive_items
    add_foreign_key :drive_item_access_logs, :drive_items

    change_column_null :drive_item_access_logs, :drive_item_id, false
    remove_column :drive_item_access_logs, :metadata
    remove_column :drive_item_access_logs, :request_id
    remove_column :drive_item_access_logs, :user_agent
    remove_column :drive_item_access_logs, :ip_address
    rename_column :drive_item_access_logs, :occurred_at, :accessed_at

    remove_column :drive_items, :content_type
    remove_column :drive_items, :file_size
  end
end
