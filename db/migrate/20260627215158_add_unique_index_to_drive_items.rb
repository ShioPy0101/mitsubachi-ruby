class AddUniqueIndexToDriveItems < ActiveRecord::Migration[8.1]
  def change
    add_index :drive_items,
              [ :organization_id, :parent_id, :name, :extension ],
              unique: true,
              name: "index_drive_items_on_org_parent_name_extension"
  end
end
