class OrganizationMembership < ApplicationRecord
  enum :role, {
    member: 0,
    organization_admin: 1
  }

  enum :status, {
    invited: 0,
    active: 1,
    suspended: 2,
    left: 3,
    removed: 4
  }

  belongs_to :user
  belongs_to :organization

  validates :user_id, uniqueness: { scope: :organization_id }
  validates :role, presence: true
  validates :status, presence: true

  before_validation :set_joined_at, if: :active?

  private

  def set_joined_at
    self.joined_at ||= Time.current
  end
end
