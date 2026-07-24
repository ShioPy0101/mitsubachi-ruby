class CreateUserEmailChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :user_email_changes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :new_email, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.datetime :cancelled_at

      t.timestamps
    end

    add_index :user_email_changes, :token_digest, unique: true
    add_index :user_email_changes,
              :user_id,
              unique: true,
              where: "used_at IS NULL AND cancelled_at IS NULL",
              name: "index_active_email_changes_on_user_id"
    add_index :user_email_changes,
              "lower(new_email)",
              unique: true,
              where: "used_at IS NULL AND cancelled_at IS NULL",
              name: "index_active_email_changes_on_lower_new_email"
  end
end
