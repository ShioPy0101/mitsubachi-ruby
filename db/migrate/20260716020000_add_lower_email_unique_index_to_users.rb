class AddLowerEmailUniqueIndexToUsers < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :users,
              "LOWER(email)",
              unique: true,
              name: "index_users_on_lower_email_unique",
              algorithm: :concurrently

    # LOWER(email) の一意制約が大小文字違いも防ぐため、従来の email 単体 unique index は冗長になる。
    remove_index :users, name: "index_users_on_email", algorithm: :concurrently
  end

  def down
    add_index :users, :email, unique: true, algorithm: :concurrently
    remove_index :users, name: "index_users_on_lower_email_unique", algorithm: :concurrently
  end
end
