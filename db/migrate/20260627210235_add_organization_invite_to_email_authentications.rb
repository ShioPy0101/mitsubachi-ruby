class AddOrganizationInviteToEmailAuthentications < ActiveRecord::Migration[8.1]
  def change
    add_reference :email_authentications, :organization_invite, foreign_key: true
  end
end