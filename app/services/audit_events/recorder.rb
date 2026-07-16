module AuditEvents
  class Recorder
    SENSITIVE_METADATA_KEYS = %w[
      password
      token
      raw_token
      encrypted_password
      reset_password_token
      cookie
      authorization
    ].freeze

    def self.record!(...)
      new(...).record!
    end

    def initialize(action:, actor_user: nil, organization: nil, target: nil, outcome: "success", changes: {}, metadata: {}, request: nil)
      @action = action
      @actor_user = actor_user
      @organization = organization
      @target = target
      @outcome = outcome
      @changes = changes
      @metadata = metadata
      @request = request
    end

    def record!
      AuditEvent.create!(
        organization: @organization,
        actor_user: @actor_user,
        action: @action,
        outcome: @outcome,
        target_type: @target&.class&.name,
        target_id: @target&.id,
        change_set: sanitized_hash(@changes),
        metadata: sanitized_hash(@metadata),
        ip_address: @request&.remote_ip,
        user_agent: @request&.user_agent.to_s,
        request_id: @request&.request_id.to_s,
        occurred_at: Time.current
      )
    rescue StandardError => error
      Rails.logger.error(
        "[audit_events.recorder] failed action=#{@action} outcome=#{@outcome} " \
        "error=#{error.class}: #{error.message}"
      )
      nil
    end

    private

    def sanitized_hash(value)
      value.to_h.deep_stringify_keys.except(*SENSITIVE_METADATA_KEYS)
    end
  end
end
