module OperationLogs
  class Recorder
    def self.record!(...)
      new(...).record!
    end

    def initialize(operation_type:, actor_kind: nil, actor_user: nil, actor_external_share: nil, organization: nil, target: nil, result: "success", changes: {}, metadata: {}, request: nil)
      @operation_type = operation_type
      @actor_kind = actor_kind || inferred_actor_kind(actor_user, actor_external_share)
      @actor_user = actor_user
      @actor_external_share = actor_external_share
      @organization = organization
      @target = target
      @result = result
      @changes = changes
      @metadata = metadata
      @request = request
    end

    def record!
      OperationLog.create!(
        actor_kind: @actor_kind,
        actor_user: @actor_user,
        actor_external_share: @actor_external_share,
        organization: @organization,
        operation_type: @operation_type,
        result: @result,
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
        "[operation_logs.recorder] failed operation_type=#{@operation_type} result=#{@result} " \
        "error=#{error.class}: #{error.message}"
      )
      nil
    end

    private

    def inferred_actor_kind(actor_user, actor_external_share)
      return "user" if actor_user.present?
      return "external_share" if actor_external_share.present?

      "anonymous"
    end

    def sanitized_hash(value)
      OperationLogs::Sanitizer.new(value).call
    end
  end
end
