class AddFileMetadataToDriveItems < ActiveRecord::Migration[8.0]
  def change
    add_column :drive_items, :extension, :string
  end
end