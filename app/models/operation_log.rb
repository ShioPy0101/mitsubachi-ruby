class OperationLog < ApplicationRecord
  ACTOR_KINDS = %w[user external_share anonymous].freeze
  RESULTS = %w[success failure denied].freeze

  belongs_to :organization, optional: true
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :actor_external_share, class_name: "ExternalShare", optional: true

  before_validation :normalize_actor_kind

  validates :actor_kind, inclusion: { in: ACTOR_KINDS }
  validates :operation_type, :occurred_at, presence: true
  validates :result, inclusion: { in: RESULTS }
  validate :actor_matches_kind

  private

  def normalize_actor_kind
    self.actor_kind = "user" if actor_user_id.present?
    self.actor_kind = "external_share" if actor_external_share_id.present?
    self.actor_kind = "anonymous" if actor_kind.blank?
  end

  def actor_matches_kind
    case actor_kind
    when "user"
      errors.add(:actor_user, "を指定してください") if actor_user_id.nil?
      errors.add(:actor_external_share, "は指定できません") if actor_external_share_id.present?
    when "external_share"
      errors.add(:actor_external_share, "を指定してください") if actor_external_share_id.nil?
      errors.add(:actor_user, "は指定できません") if actor_user_id.present?
    when "anonymous"
      errors.add(:actor_user, "は指定できません") if actor_user_id.present?
      errors.add(:actor_external_share, "は指定できません") if actor_external_share_id.present?
    end
  end
end
