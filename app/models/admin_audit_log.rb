class AdminAuditLog < ApplicationRecord
  ACTIONS = %w[
    organization.update
    user.update
    user.role_change
    user.suspend
    user.unsuspend
    drive_item.delete
    drive_item.restore
  ].freeze

  belongs_to :actor_user, class_name: "User"
  belongs_to :organization

  validates :action, inclusion: { in: ACTIONS }
  validates :target_type, :target_id, presence: true
end
