class CreateOrganizationInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_invites do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :code
      t.datetime :expires_at
      t.datetime :used_at

      t.timestamps
    end
  end
end
