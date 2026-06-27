class AddDeletedAtToDriveItems < ActiveRecord::Migration[8.1]
  def change
    add_column :drive_items, :deleted_at, :datetime
    add_index :drive_items, :deleted_at
  end
end