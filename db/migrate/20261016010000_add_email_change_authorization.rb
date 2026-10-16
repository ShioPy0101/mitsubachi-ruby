class AddEmailChangeAuthorization < ActiveRecord::Migration[8.1]
  def change
    add_column :email_authentications, :email_change_reauthentication, :boolean, default: false, null: false
    add_column :email_authentications, :recipient_ciphertext, :text
    add_column :email_authentications, :reauthentication_consumed_at, :datetime

    add_column :user_email_changes, :old_email_digest, :string, limit: 64
    add_column :user_email_changes, :delivery_addresses_ciphertext, :text
    add_column :user_email_changes, :old_email_approved_at, :datetime
  end
end
