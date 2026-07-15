class DriveItemAccessLog < ApplicationRecord
  ACTIONS = %w[preview download stream bulk_download].freeze

  belongs_to :organization
  belongs_to :user
  belongs_to :drive_item, optional: true

  scope :for_organization, ->(organization) { where(organization: organization) }
  scope :recent_stream_for, lambda { |organization:, user:, drive_item:, since:|
    for_organization(organization)
      .where(user: user, drive_item: drive_item, action: "stream")
      .where("occurred_at >= ?", since)
  }

  validates :action, inclusion: { in: ACTIONS }
  validates :occurred_at, :ip_address, :request_id, presence: true
end
