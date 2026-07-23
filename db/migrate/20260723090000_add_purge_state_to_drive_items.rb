class AddPurgeStateToDriveItems < ActiveRecord::Migration[8.1]
  ACTIVE_NAME_INDEX = "index_active_drive_items_on_org_parent_name_extension"

  def change
    add_column :drive_items, :purged_at, :datetime
    add_reference :drive_items,
                  :purged_by_user,
                  null: true,
                  foreign_key: { to_table: :users }
    add_index :drive_items, :purged_at

    remove_index :drive_items, name: ACTIVE_NAME_INDEX
    add_index :drive_items,
              [ :organization_id, :parent_id, :name, :extension ],
              unique: true,
              where: "deleted_at IS NULL AND purged_at IS NULL",
              name: ACTIVE_NAME_INDEX

    add_index :drive_items,
              [ :organization_id, :file_hash ],
              where: "purged_at IS NULL",
              name: "index_non_purged_drive_items_on_org_and_hash"
  end
end
