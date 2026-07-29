class UploadMetric < ApplicationRecord
  STATUSES = %w[in_progress completed completed_with_errors failed cancelled abandoned].freeze
  KINDS = %w[single multiple folder].freeze
  MAX_FILES = 10_000_000
  MAX_BYTES = 10.petabytes

  belongs_to :organization
  belongs_to :user

  validates :upload_session_id, presence: true, uniqueness: true,
            format: { with: /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i }
  validates :status, inclusion: { in: STATUSES }
  validates :upload_kind, inclusion: { in: KINDS }
  validates :total_files, :completed_files, :failed_files, :retried_files,
            :retry_count, :cancelled_files, :under_1mb_count,
            :between_1mb_and_100mb_count, :between_100mb_and_1gb_count,
            :over_1gb_count, numericality: { only_integer: true, in: 0..MAX_FILES }
  validates :total_bytes, :completed_bytes, :elapsed_ms,
            :effective_throughput_bytes_per_second, :min_file_size_bytes,
            :max_file_size_bytes, :average_file_size_bytes,
            :long_task_total_duration_ms, :long_task_max_duration_ms,
            :background_duration_ms,
            numericality: { only_integer: true, in: 0..MAX_BYTES }
  validates :max_concurrency, numericality: { only_integer: true, in: 0..100 }
  validates :max_relative_depth, numericality: { only_integer: true, in: 0..1_000 }
  validates :progress_stall_count, :long_task_count,
            numericality: { only_integer: true, in: 0..MAX_FILES }
  validate :request_ids_are_bounded_uuids

  scope :stale_in_progress, ->(before) { where(status: "in_progress", last_observed_at: ...before) }

  private

  def request_ids_are_bounded_uuids
    values = Array(request_ids)
    errors.add(:request_ids, "は500件以下にしてください") if values.length > 500
    return if values.all? { |value| value.to_s.match?(/\A[0-9a-f-]{36}\z/i) }

    errors.add(:request_ids, "に不正な値があります")
  end
end
