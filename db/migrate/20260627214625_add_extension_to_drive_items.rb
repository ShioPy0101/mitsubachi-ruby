class AddExtensionToDriveItems < ActiveRecord::Migration[8.1]
  def change
    add_column :drive_items, :extension, :string
  end
end
