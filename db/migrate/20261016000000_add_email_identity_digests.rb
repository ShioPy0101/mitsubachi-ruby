# 平文の削除は自動 migration に含めない。バックフィル・全件照合後に専用タスクで実施する。
class AddEmailIdentityDigests < ActiveRecord::Migration[8.1]
  def change
    create_table :email_identity_keys do |t|
      t.string :fingerprint, null: false
    end

    add_column :users, :email_digest, :string, limit: 64
    add_index :users, :email_digest, unique: true
    change_column_null :users, :email, true

    add_column :email_authentications, :email_digest, :string, limit: 64
    add_index :email_authentications, :email_digest

    add_column :organization_invites, :email_digest, :string, limit: 64
    add_index :organization_invites, :email_digest

    add_column :user_email_changes, :new_email_digest, :string, limit: 64
    change_column_null :user_email_changes, :new_email, true
    add_index :user_email_changes, :new_email_digest, unique: true,
              where: "used_at IS NULL AND cancelled_at IS NULL",
              name: "index_active_email_changes_on_new_email_digest"
  end
end
