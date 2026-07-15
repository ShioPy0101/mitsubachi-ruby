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

  def suspended?
    suspended_at.present?
  end
end
