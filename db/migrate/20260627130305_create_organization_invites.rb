class CreateOrganizationInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_invites do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :used_by_user, null: true, foreign_key: { to_table: :users }
      t.string :code, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.timestamps
    end

    # organization_invitesテーブルのcodeカラムに一意制約を追加する
    add_index :organization_invites, :code, unique: true
  end
end
