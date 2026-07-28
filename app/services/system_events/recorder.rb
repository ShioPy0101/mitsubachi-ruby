module SystemEvents
  class Recorder
    def self.record!(...)
      new(...).record!
    end

    def initialize(event_type:, severity:, source:, organization: nil, related_user: nil, target: nil, request: nil, request_id: nil, job_id: nil, trace_id: nil, error: nil, metadata: {})
      @event_type = event_type
      @severity = severity
      @source = source
      @organization = organization
      @related_user = related_user
      @target = target
      @request_id = request_id.presence || request&.request_id
      @job_id = job_id
      @trace_id = trace_id.presence || request&.headers&.fetch("X-Trace-Id", nil)
      @error = error
      @metadata = metadata
    end

    def record!
      SystemEvent.create!(
        event_type: @event_type,
        severity: @severity,
        source: @source,
        organization: @organization,
        related_user: @related_user,
        target_type: @target&.class&.name,
        target_id: @target&.id,
        request_id: @request_id,
        job_id: @job_id,
        trace_id: @trace_id,
        error_class: @error&.class&.name,
        error_message: @error && Sanitizer.safe_error_message(@error),
        metadata: Sanitizer.new(@metadata).call,
        occurred_at: Time.current
      )
    rescue StandardError => recorder_error
      Rails.logger.error(
        "[system_events.recorder] failed event_type=#{@event_type} " \
        "error=#{recorder_error.class}: #{recorder_error.message}"
      )
      nil
    end
  end
end
