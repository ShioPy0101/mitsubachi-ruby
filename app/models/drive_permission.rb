class DrivePermission < ApplicationRecord
  # この権限は1つのDriveItemに属する
  belongs_to :drive_item

  # この権限は1つのUserに属する
  belongs_to :user
end
