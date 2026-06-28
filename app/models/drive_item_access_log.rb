class DriveItemAccessLog < ApplicationRecord
  belongs_to :organization
  belongs_to :user
  belongs_to :drive_item
end
