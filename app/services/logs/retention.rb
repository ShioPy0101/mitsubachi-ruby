module Logs
  class Retention
    ENV_KEYS = {
      operation_logs: "OPERATION_LOG_RETENTION_DAYS",
      drive_item_access_logs: "DRIVE_ITEM_ACCESS_LOG_RETENTION_DAYS",
      system_info: "SYSTEM_EVENT_INFO_RETENTION_DAYS",
      system_warning: "SYSTEM_EVENT_WARNING_RETENTION_DAYS",
      system_error: "SYSTEM_EVENT_ERROR_RETENTION_DAYS",
      system_critical: "SYSTEM_EVENT_CRITICAL_RETENTION_DAYS"
    }.freeze

    def initialize(retention_days: configured_days, batch_size: 1_000, now: Time.current)
      @retention_days = retention_days
      @batch_size = batch_size
      @now = now
    end

    def call
      deleted = {}
      deleted[:operation_logs] = delete_batches(OperationLog.where(occurred_at: ...cutoff(:operation_logs)))
      deleted[:drive_item_access_logs] = delete_batches(DriveItemAccessLog.where(occurred_at: ...cutoff(:drive_item_access_logs)))
      SystemEvent::SEVERITIES.each do |severity|
        key = :"system_#{severity}"
        deleted[key] = delete_batches(SystemEvent.where(severity: severity, occurred_at: ...cutoff(key)))
      end

      SystemEvents::Recorder.record!(
        event_type: "maintenance.log_retention_completed", severity: "info", source: "maintenance",
        metadata: { deleted_counts: deleted }
      )
      deleted
    end

    private

    def configured_days
      ENV_KEYS.to_h { |key, env_key| [ key, positive_days(ENV[env_key]) ] }
    end

    def positive_days(value)
      days = Integer(value, exception: false)
      days if days&.positive?
    end

    def cutoff(key)
      days = @retention_days[key]
      days ? @now - days.days : Time.at(0)
    end

    def delete_batches(scope)
      count = 0
      scope.in_batches(of: @batch_size) { |batch| count += batch.delete_all }
      count
    end
  end
end
