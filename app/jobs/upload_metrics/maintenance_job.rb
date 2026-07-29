class UploadMetrics::MaintenanceJob < ApplicationJob
  queue_as :default

  def perform(
    abandoned_after_minutes: ENV.fetch("UPLOAD_METRIC_ABANDONED_AFTER_MINUTES", "120").to_i,
    retention_days: ENV.fetch("UPLOAD_METRIC_RETENTION_DAYS", "180").to_i
  )
    abandoned_cutoff = abandoned_after_minutes.clamp(5, 10_080).minutes.ago
    abandoned = UploadMetric.stale_in_progress(abandoned_cutoff).update_all(status: "abandoned", completed_at: Time.current)
    retention_cutoff = retention_days.clamp(30, 3650).days.ago
    deleted = UploadMetric.where(started_at: ...retention_cutoff).delete_all
    Rails.logger.info({ event: "upload_metrics_maintained", abandoned_count: abandoned,
                        deleted_count: deleted, abandoned_cutoff: abandoned_cutoff.iso8601,
                        retention_cutoff: retention_cutoff.iso8601 }.to_json)
  end
end
