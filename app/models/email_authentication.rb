class EmailAuthentication < ApplicationRecord
  belongs_to :organization_invite, optional: true

  validates :email, :token, :expires_at, presence: true
  validates :token, uniqueness: true
end
