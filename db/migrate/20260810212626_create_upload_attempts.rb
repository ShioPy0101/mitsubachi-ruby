class CreateUploadAttempts < ActiveRecord::Migration[8.1]
  def change
    create_table :upload_attempts do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :drive_item, foreign_key: true
      t.string :client_upload_id, null: false
      t.string :state, null: false
      t.string :block_reason
      t.string :file_hash
      t.string :staging_path
      t.string :storage_key
      t.string :error_code
      t.bigint :retry_count, null: false, default: 0
      t.datetime :last_transition_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :upload_attempts,
              [ :organization_id, :client_upload_id ],
              unique: true,
              name: "index_upload_attempts_on_org_and_client_upload_id"
    add_index :upload_attempts, [ :state, :updated_at ]
    add_index :upload_attempts, :file_hash
  end
end
