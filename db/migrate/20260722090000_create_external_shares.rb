class CreateExternalShares < ActiveRecord::Migration[8.1]
  def change
    create_table :external_shares do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :password_digest
      t.string :folder_share_mode, null: false, default: "snapshot"
      t.datetime :expires_at
      t.datetime :revoked_at
      t.boolean :allow_download, null: false, default: true
      t.boolean :allow_bulk_download, null: false, default: false
      t.timestamps
    end

    add_index :external_shares, :token_digest, unique: true
    add_index :external_shares, [ :organization_id, :created_by_user_id ]
    add_check_constraint :external_shares,
                         "folder_share_mode IN ('snapshot', 'dynamic')",
                         name: "external_shares_folder_share_mode_check"

    create_table :external_share_items do |t|
      t.references :external_share, null: false, foreign_key: true
      t.references :drive_item, null: false, foreign_key: true
      t.timestamps
    end

    add_index :external_share_items,
              [ :external_share_id, :drive_item_id ],
              unique: true
  end
end
