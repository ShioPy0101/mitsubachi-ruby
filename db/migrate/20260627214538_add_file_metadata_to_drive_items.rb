class AddFileMetadataToDriveItems < ActiveRecord::Migration[8.1]
  def change
    add_column :drive_items, :extension, :string
    add_column :drive_items, :blob_path, :string
    add_column :drive_items, :content_hash, :string
  end
end
