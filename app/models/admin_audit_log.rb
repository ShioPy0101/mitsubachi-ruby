class AdminAuditLog < ApplicationRecord
  ACTIONS = %w[
    organization.created
    organization.settings_updated
    organization.invitation_created
    user.updated
    organization.membership_role_changed
    user.suspended
    user.unsuspended
    drive_item.deleted
    drive_item.restored
    drive_item.purged
  ].freeze

  belongs_to :actor_user, class_name: "User"
  belongs_to :organization

  validates :action, inclusion: { in: ACTIONS }
  validates :target_type, :target_id, presence: true
end
