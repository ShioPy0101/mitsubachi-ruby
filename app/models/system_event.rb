class SystemEvent < ApplicationRecord
  SEVERITIES = %w[info warning error critical].freeze
  SOURCES = %w[application worker mailer storage database maintenance].freeze

  belongs_to :organization, optional: true
  belongs_to :related_user, class_name: "User", optional: true

  validates :event_type, :source, :occurred_at, presence: true
  validates :severity, inclusion: { in: SEVERITIES }
  validates :source, inclusion: { in: SOURCES }
end
