class UseActiveUniqueIndexForDriveItems < ActiveRecord::Migration[8.1]
  OLD_INDEX_NAME = "index_drive_items_on_org_parent_name_extension"
  NEW_INDEX_NAME = "index_active_drive_items_on_org_parent_name_extension"

  def change
    remove_index :drive_items, name: OLD_INDEX_NAME

    add_index :drive_items,
              [ :organization_id, :parent_id, :name, :extension ],
              unique: true,
              where: "deleted_at IS NULL",
              name: NEW_INDEX_NAME
  end
end
