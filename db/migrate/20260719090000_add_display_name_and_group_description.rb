class AddDisplayNameAndGroupDescription < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :display_name, :string
    add_column :organizations, :description, :text

    add_index :users, [ :organization_id, :display_name ],
              unique: true,
              where: "display_name IS NOT NULL",
              name: "index_users_on_org_id_and_display_name"
  end
end
