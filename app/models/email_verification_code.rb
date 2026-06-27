class EmailVerificationCode < ApplicationRecord
  belongs_to :user
end
