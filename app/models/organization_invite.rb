class OrganizationInvite < ApplicationRecord
  self.ignored_columns += [ "email" ]
  attr_reader :email

  def email=(value)
    EmailIdentityKey.verify!
    @email = EmailIdentities::Digest.normalize(value).presence
    self.email_digest = @email && EmailIdentities::Digest.call(@email)
  end

  def reload(*)
    @email = nil
    super
  end

  enum :role, {
    member: 0,
    organization_admin: 1
  }

  # この招待は1つのOrganizationに属する
  belongs_to :organization

  # この招待を使用したUser
  belongs_to :used_by_user, class_name: "User", optional: true

  belongs_to :invited_by_user, class_name: "User", optional: true

  # この招待を仮ユーザーとして使用するUser
  belongs_to :stand_by_user, class_name: "User", optional: true

  has_many :email_authentications, dependent: :restrict_with_error

  validates :code, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :role, presence: true

  def accepted?
    used_at.present?
  end

  def revoked?
    revoked_at.present?
  end

end
