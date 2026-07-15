class AddUniqueIndexToEmailAuthenticationsToken < ActiveRecord::Migration[8.1]
  def change
    add_index :email_authentications, :token, unique: true
  end
end
