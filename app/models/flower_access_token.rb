class FlowerAccessToken < ApplicationRecord
  DEFAULT_SCOPES = %w[flower:read flower:download].freeze

  belongs_to :user
  belongs_to :organization
  belongs_to :flower_device_authorization, optional: true

  validates :access_token_digest, :expires_at, presence: true
  validates :access_token_digest, uniqueness: true
  validate :user_belongs_to_organization

  def expired?
    expires_at <= Time.current
  end

  def revoked?
    revoked_at.present?
  end

  def active?
    !expired? && !revoked?
  end

  def has_scope?(scope)
    scopes.include?(scope)
  end

  private

  def user_belongs_to_organization
    return if user.blank? || organization.blank?
    return if user.organization_id == organization_id

    errors.add(:organization, "must match the token user")
  end
end
