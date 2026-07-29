class CreateUploadMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :upload_metrics do |t|
      t.uuid :upload_session_id, null: false
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :upload_kind, null: false, default: "single"
      t.string :status, null: false, default: "in_progress"
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.datetime :last_observed_at, null: false
      t.bigint :total_files, null: false, default: 0
      t.bigint :total_bytes, null: false, default: 0
      t.bigint :completed_files, null: false, default: 0
      t.bigint :completed_bytes, null: false, default: 0
      t.bigint :failed_files, null: false, default: 0
      t.bigint :retried_files, null: false, default: 0
      t.bigint :retry_count, null: false, default: 0
      t.bigint :cancelled_files, null: false, default: 0
      t.integer :max_concurrency, null: false, default: 1
      t.bigint :elapsed_ms, null: false, default: 0
      t.bigint :effective_throughput_bytes_per_second, null: false, default: 0
      t.bigint :min_file_size_bytes, null: false, default: 0
      t.bigint :max_file_size_bytes, null: false, default: 0
      t.bigint :average_file_size_bytes, null: false, default: 0
      t.integer :max_relative_depth, null: false, default: 0
      t.bigint :under_1mb_count, null: false, default: 0
      t.bigint :between_1mb_and_100mb_count, null: false, default: 0
      t.bigint :between_100mb_and_1gb_count, null: false, default: 0
      t.bigint :over_1gb_count, null: false, default: 0
      t.bigint :progress_stall_count, null: false, default: 0
      t.bigint :long_task_count, null: false, default: 0
      t.bigint :long_task_total_duration_ms, null: false, default: 0
      t.bigint :long_task_max_duration_ms, null: false, default: 0
      t.bigint :background_duration_ms, null: false, default: 0
      t.string :frontend_version
      t.string :backend_version
      t.jsonb :http_status_counts, null: false, default: {}
      t.jsonb :error_code_counts, null: false, default: {}
      t.jsonb :request_ids, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :upload_metrics, :upload_session_id, unique: true
    add_index :upload_metrics, :started_at
    add_index :upload_metrics, %i[organization_id started_at]
    add_index :upload_metrics, %i[status started_at]
    add_index :upload_metrics, %i[user_id started_at]
    add_index :upload_metrics, %i[status last_observed_at]
  end
end
