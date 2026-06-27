class DrivePermission < ApplicationRecord
  belongs_to :drive_item
  belongs_to :user
end
