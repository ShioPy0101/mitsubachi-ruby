class EmailAuthentication < ApplicationRecord
  PURPOSES = %w[registration login].freeze

  belongs_to :organization_invite, optional: true

  validates :email, :token, :expires_at, :purpose, presence: true
  validates :token, uniqueness: true
  validates :purpose, inclusion: { in: PURPOSES }

  def registration?
    purpose == "registration"
  end

  def login?
    purpose == "login"
  end
end
