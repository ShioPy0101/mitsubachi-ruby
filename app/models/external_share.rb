class ExternalShare < ApplicationRecord
  has_secure_password validations: false

  belongs_to :organization
  belongs_to :created_by_user, class_name: "User"
  has_many :external_share_items, dependent: :destroy
  has_many :drive_items, through: :external_share_items

  enum :folder_share_mode, {
    snapshot: "snapshot",
    dynamic: "dynamic"
  }, validate: true

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validate :expires_at_is_in_the_future
  validate :bulk_download_requires_file_download

  scope :active, -> {
    where(revoked_at: nil)
      .where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  def active?
    revoked_at.blank? && (expires_at.blank? || expires_at.future?)
  end

  def password_required?
    password_digest.present?
  end

  def revoked?
    revoked_at.present?
  end

  private

  def expires_at_is_in_the_future
    return if expires_at.blank?
    return if expires_at.future?

    errors.add(:expires_at, "must be in the future")
  end

  def bulk_download_requires_file_download
    return unless allow_bulk_download? && !allow_download?

    errors.add(:allow_bulk_download, "requires allow_download")
  end
end
