class ExternalShareItem < ApplicationRecord
  belongs_to :external_share
  belongs_to :drive_item

  validates :drive_item_id, uniqueness: { scope: :external_share_id }
end
