class OrganizationInvite < ApplicationRecord
  # この招待は1つのOrganizationに属する
  belongs_to :organization

  # この招待を使用したUser
  belongs_to :used_by_user, class_name: "User", optional: true

  # この招待を仮ユーザーとして使用するUser
  belongs_to :stand_by_user, class_name: "User", optional: true

  has_many :email_authentications, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :expires_at, presence: true
end
