module AuditEvents
  class Recorder
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
      OperationLogs::Recorder.record!(
        operation_type: @action,
        actor_user: @actor_user,
        organization: @organization,
        target: @target,
        result: @outcome,
        changes: @changes,
        metadata: @metadata,
        request: @request
      )
    end
  end
end
