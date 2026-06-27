class CreateEmailAuthentications < ActiveRecord::Migration[8.1]
  def change
    create_table :email_authentications do |t|
      t.string :email
      t.string :token
      t.datetime :expires_at
      t.datetime :used_at

      t.timestamps
    end
  end
end
