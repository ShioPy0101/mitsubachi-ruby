class FlowerDeviceAuthorization < ApplicationRecord
  STATUSES = %w[pending approved denied consumed expired].freeze

  belongs_to :user, optional: true
  belongs_to :organization, optional: true
  has_many :flower_access_tokens, dependent: :restrict_with_error

  validates :device_code_digest, :user_code_digest, :status, :expires_at, :interval_seconds, presence: true
  validates :device_code_digest, :user_code_digest, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :interval_seconds, numericality: { only_integer: true, greater_than: 0 }
  validate :approved_authorization_has_user_and_organization

  def expired?
    expires_at <= Time.current
  end

  def terminal?
    denied? || consumed? || expired_status?
  end

  def pending?
    status == "pending"
  end

  def approved?
    status == "approved"
  end

  def denied?
    status == "denied"
  end

  def consumed?
    status == "consumed"
  end

  def expired_status?
    status == "expired"
  end

  private

  def approved_authorization_has_user_and_organization
    return unless approved? || consumed?
    return if user_id.present? && organization_id.present?

    errors.add(:base, "approved authorization must have user and organization")
  end
end
