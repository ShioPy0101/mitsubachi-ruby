class RemoveFlowerPersistence < ActiveRecord::Migration[8.1]
  def up
    drop_table :flower_access_tokens
    drop_table :flower_device_authorizations
  end

  def down
    create_table :flower_device_authorizations do |t|
      t.string :device_code_digest, null: false
      t.string :user_code_digest, null: false
      t.string :status, null: false, default: "pending"
      t.references :user, foreign_key: true
      t.references :organization, foreign_key: true
      t.integer :interval_seconds, null: false, default: 5
      t.datetime :expires_at, null: false
      t.datetime :last_polled_at
      t.datetime :approved_at
      t.datetime :denied_at
      t.datetime :consumed_at
      t.jsonb :client_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :flower_device_authorizations, :device_code_digest, unique: true
    add_index :flower_device_authorizations, :user_code_digest, unique: true
    add_index :flower_device_authorizations, [ :status, :expires_at ]
    add_check_constraint :flower_device_authorizations,
                         "status IN ('pending', 'approved', 'denied', 'consumed', 'expired')",
                         name: "flower_device_authorizations_status_check"

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
