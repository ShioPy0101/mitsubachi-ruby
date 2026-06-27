class AddStandByToOrganizationInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :organization_invites, :stand_by_at, :datetime
    add_reference :organization_invites, :stand_by_user, null: false, foreign_key: true
  end
end
