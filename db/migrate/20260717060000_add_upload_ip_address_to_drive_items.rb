class AddUploadIpAddressToDriveItems < ActiveRecord::Migration[8.1]
  def change
    add_column :drive_items, :upload_ip_address, :string
  end
end
