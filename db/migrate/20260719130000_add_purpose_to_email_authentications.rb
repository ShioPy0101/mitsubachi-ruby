class AddPurposeToEmailAuthentications < ActiveRecord::Migration[8.1]
  def up
    add_column :email_authentications, :purpose, :string, null: false, default: "login"

    EmailAuthentication.reset_column_information
    EmailAuthentication.where.not(organization_invite_id: nil).update_all(purpose: "registration")

    add_index :email_authentications, :purpose
  end

  def down
    remove_index :email_authentications, :purpose
    remove_column :email_authentications, :purpose
  end
end
