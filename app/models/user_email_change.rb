class UserEmailChange < ApplicationRecord
  TOKEN_TTL = 30.minutes

  belongs_to :user

  before_validation :normalize_new_email

  validates :new_email, presence: true
  validates :new_email, format: { with: Devise.email_regexp }, if: -> { new_email.present? }
  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validate :new_email_is_not_current_email
  validate :new_email_is_available
  validate :new_email_is_not_pending_elsewhere

  scope :active, -> { where(used_at: nil, cancelled_at: nil) }

  def self.digest_token(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  def self.generate_token_pair
    raw_token = SecureRandom.urlsafe_base64(32)
    [ raw_token, digest_token(raw_token) ]
  end

  def expired?(now = Time.current)
    expires_at <= now
  end

  def used?
    used_at.present?
  end

  def cancelled?
    cancelled_at.present?
  end

  private

  def normalize_new_email
    self.new_email = new_email.to_s.strip.downcase if new_email.present?
  end

  def new_email_is_not_current_email
    return if user.blank? || new_email.blank?
    return unless new_email == user.email.to_s.downcase

    errors.add(:new_email, "は現在のメールアドレスと異なるものを入力してください")
  end

  def new_email_is_available
    return if new_email.blank?

    scope = User.where("LOWER(email) = ?", new_email.downcase)
    scope = scope.where.not(id: user_id) if user_id.present?
    return unless scope.exists?

    errors.add(:new_email, "は既に使用されています")
  end

  def new_email_is_not_pending_elsewhere
    return if new_email.blank?

    scope = UserEmailChange.active.where("LOWER(new_email) = ?", new_email.downcase)
    scope = scope.where.not(id: id) if id.present?
    return unless scope.exists?

    errors.add(:new_email, "は現在確認待ちです")
  end
end
