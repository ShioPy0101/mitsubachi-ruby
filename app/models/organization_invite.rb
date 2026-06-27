class OrganizationInvite < ApplicationRecord
  # この招待は1つのOrganizationに属する
  belongs_to :organization

  # この招待を使用したUser
  belongs_to :used_by_user, class_name: "User", optional: true
end
