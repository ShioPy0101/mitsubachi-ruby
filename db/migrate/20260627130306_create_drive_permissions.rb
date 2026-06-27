class CreateDrivePermissions < ActiveRecord::Migration[8.1]
  def change
    create_table :drive_permissions do |t|
      t.references :drive_item, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :permission

      t.timestamps
    end
  end
end
