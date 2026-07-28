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
        metadata: sanitized_hash(@metadata.merge(snapshot_metadata)),
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

    def snapshot_metadata
      {
        target_type: @target&.class&.name,
        target_id: @target&.id,
        target_name: target_name,
        target_path: target_path,
        organization_name: @organization&.name,
        actor_email: @actor_user&.email,
        actor_display_name: @actor_user&.display_name
      }.compact
    end

    def target_name
      return if @target.nil?
      return @target.filename if @target.respond_to?(:filename)
      return @target.name if @target.respond_to?(:name)
      return @target.email if @target.respond_to?(:email)

      @target.to_s
    end

    def target_path
      return drive_item_path if @target.is_a?(DriveItem)
      return unless @target.respond_to?(:path)

      @target.path
    end

    def drive_item_path
      components = []
      item = @target
      while item
        components.unshift(item.filename)
        item = item.parent
      end
      components.join("/")
    end
  end
end
