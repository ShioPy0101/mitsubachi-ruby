class User < ApplicationRecord
  enum :role, {
    member: 0,
    organization_admin: 1,
    system_admin: 2
  }

  # このユーザーは1つのOrganizationに所属する
  belongs_to :organization

  # このユーザーに付与されたDrivePermission
  has_many :drive_permissions, dependent: :restrict_with_error

  # このユーザーがアクセス権を持つDriveItem
  has_many :drive_items, through: :drive_permissions

  # このユーザーが使用した招待コード
  has_many :organization_invites,
           foreign_key: :used_by_user_id,
           dependent: :restrict_with_error

  has_many :admin_audit_logs,
           foreign_key: :actor_user_id,
           dependent: :restrict_with_error

  scope :active, -> { where(suspended_at: nil) }
  scope :suspended, -> { where.not(suspended_at: nil) }

  devise :database_authenticatable,
         :registerable,
         :recoverable,
         :rememberable,
         :validatable

  before_validation :normalize_email
  before_validation :normalize_display_name

  validates :email, uniqueness: { case_sensitive: false }
  validates :display_name,
            length: { maximum: 50 },
            uniqueness: { scope: :organization_id, allow_blank: true }
  validate :display_name_has_no_control_characters

  def safe_display_name
    display_name.presence || name.presence || "未設定ユーザー"
  end

  def suspended?
    suspended_at.present?
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase if email.present?
  end

  def normalize_display_name
    self.display_name = display_name.to_s.strip.presence if display_name.present?
  end

  def display_name_has_no_control_characters
    return if display_name.blank?
    return unless display_name.match?(/[[:cntrl:]]/)

    errors.add(:display_name, "に制御文字は使用できません")
  end
end
