class AddAdminFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :role, :integer, null: false, default: 0
    add_column :users, :suspended_at, :datetime
    add_column :users, :last_sign_in_at, :datetime

    add_index :users, :role
    add_index :users, :suspended_at
    add_index :users, :last_sign_in_at
  end
end
