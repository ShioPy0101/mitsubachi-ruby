class CreateFlowerDeviceAuthorizations < ActiveRecord::Migration[8.1]
  def change
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
  end
end
