class EmailAuthentication < ApplicationRecord
  belongs_to :organization_invite, optional: true
end
