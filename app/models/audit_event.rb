class AuditEvent < ApplicationRecord
  OUTCOMES = %w[success failure denied].freeze

  belongs_to :organization, optional: true
  belongs_to :actor_user, class_name: "User", optional: true

  validates :action, :occurred_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES }
end
