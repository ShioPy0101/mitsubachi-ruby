class DriveItemAccessLog < ApplicationRecord
  ACTOR_KINDS = %w[user external_share anonymous].freeze
  ACTIONS = %w[preview download stream bulk_download download_folder].freeze

  belongs_to :organization
  belongs_to :user, optional: true
  belongs_to :external_share, optional: true
  belongs_to :drive_item, optional: true

  scope :for_organization, ->(organization) { where(organization: organization) }
  scope :recent_stream_for, lambda { |organization:, user:, drive_item:, since:|
    for_organization(organization)
      .where(user: user, drive_item: drive_item, action: "stream")
      .where("occurred_at >= ?", since)
  }

  validates :action, inclusion: { in: ACTIONS }
  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :occurred_at, :ip_address, :request_id, presence: true
  validate :actor_matches_kind

  private

  def actor_matches_kind
    case actor_kind
    when "user"
      errors.add(:user, "を指定してください") if user_id.nil?
      errors.add(:external_share, "は指定できません") if external_share_id.present?
    when "external_share"
      errors.add(:external_share, "を指定してください") if external_share_id.nil?
      errors.add(:user, "は指定できません") if user_id.present?
    when "anonymous"
      errors.add(:user, "は指定できません") if user_id.present?
      errors.add(:external_share, "は指定できません") if external_share_id.present?
    end
  end
end
