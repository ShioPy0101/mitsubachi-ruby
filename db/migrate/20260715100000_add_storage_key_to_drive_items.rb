class AddStorageKeyToDriveItems < ActiveRecord::Migration[8.1]
  def up
    add_column :drive_items, :storage_key, :string

    execute <<~SQL
      UPDATE drive_items
      SET storage_key = TRIM(LEADING '/' FROM blob_path)
      WHERE blob_path IS NOT NULL
    SQL
  end

  def down
    remove_column :drive_items, :storage_key
  end
end
