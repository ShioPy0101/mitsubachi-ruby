class AdminAuditLog < ApplicationRecord
  ACTIONS = %w[
    organization.create
    organization.update
    organization_invite.create
    user.update
    user.role_change
    user.suspend
    user.unsuspend
    drive_item.preview
    drive_item.download
    drive_item.stream
    drive_item.delete
    drive_item.restore
    drive_item.purge
  ].freeze

  belongs_to :actor_user, class_name: "User"
  belongs_to :organization

  validates :action, inclusion: { in: ACTIONS }
  validates :target_type, :target_id, presence: true
end
