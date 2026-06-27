class User < ApplicationRecord
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
end
