class LegacyAdminAuditLog < ApplicationRecord
  belongs_to :actor_user, class_name: "User"
  belongs_to :organization
end
