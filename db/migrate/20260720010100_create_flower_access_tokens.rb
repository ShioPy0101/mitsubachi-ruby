class CreateFlowerAccessTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :flower_access_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.references :flower_device_authorization, foreign_key: true
      t.string :access_token_digest, null: false
      t.string :refresh_token_digest
      t.string :scopes, array: true, null: false, default: []
      t.datetime :expires_at, null: false
      t.datetime :refresh_expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :flower_access_tokens, :access_token_digest, unique: true
    add_index :flower_access_tokens, :refresh_token_digest, unique: true
    add_index :flower_access_tokens, [ :user_id, :organization_id ]
    add_index :flower_access_tokens, :expires_at
  end
end
