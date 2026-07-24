class CreateOrganizationMemberships < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  class MigrationOrganizationMembership < ActiveRecord::Base
    self.table_name = "organization_memberships"
  end

  def change
    create_table :organization_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.integer :role, null: false, default: 0
      t.integer :status, null: false, default: 1
      t.datetime :joined_at

      t.timestamps
    end

    add_index :organization_memberships,
              [ :organization_id, :user_id ],
              unique: true

    reversible do |dir|
      dir.up do
        migrate_existing_user_organizations!
      end
    end
  end

  private

  def migrate_existing_user_organizations!
    now = Time.current

    MigrationUser.reset_column_information
    MigrationOrganizationMembership.reset_column_information

    MigrationUser.where.not(organization_id: nil).find_each do |user|
      MigrationOrganizationMembership.find_or_create_by!(
        user_id: user.id,
        organization_id: user.organization_id
      ) do |membership|
        membership.role = user.role == 1 ? 1 : 0
        membership.status = 1
        membership.joined_at = user.created_at || now
        membership.created_at = now
        membership.updated_at = now
      end
    end
  end
end
