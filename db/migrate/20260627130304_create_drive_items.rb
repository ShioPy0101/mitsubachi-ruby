class CreateDriveItems < ActiveRecord::Migration[8.1]
  def change
    create_table :drive_items do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :parent, null: true, foreign_key: { to_table: :drive_items }
      t.references :owner_user,
             null: false,
             foreign_key: { to_table: :users }
      t.string :name
      t.integer :item_type
      t.string :blob_path
      t.string :file_hash

      t.timestamps
    end
  end
end
