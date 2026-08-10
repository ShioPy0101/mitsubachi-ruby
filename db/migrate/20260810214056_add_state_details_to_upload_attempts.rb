class AddStateDetailsToUploadAttempts < ActiveRecord::Migration[8.1]
  def change
    add_column :upload_attempts, :block_reason, :string unless column_exists?(:upload_attempts, :block_reason)
    add_column :upload_attempts, :retry_count, :bigint, null: false, default: 0 unless column_exists?(:upload_attempts, :retry_count)
    add_column :upload_attempts, :last_transition_at, :datetime unless column_exists?(:upload_attempts, :last_transition_at)
  end
end
