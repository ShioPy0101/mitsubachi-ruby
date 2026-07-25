class AddAcceptanceFieldsToOrganizationInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :organization_invites, :email, :string
    add_column :organization_invites, :role, :integer, null: false, default: 0
    add_column :organization_invites, :revoked_at, :datetime
    add_reference :organization_invites, :invited_by_user, foreign_key: { to_table: :users }

    add_index :organization_invites, "LOWER(email)", name: "index_organization_invites_on_lower_email"
    add_index :organization_invites, :revoked_at
  end
end
