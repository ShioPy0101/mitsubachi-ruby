class Api::V1::Admin::OperationLogsController < Api::V1::Admin::BaseController
  def index
    render_collection(filtered_scope.order(occurred_at: :desc, id: :desc), method(:operation_log_json))
  end

  def show
    log = scoped_operation_logs.includes(:actor_user, :actor_external_share, :organization).find_by(id: params[:id])
    return render_not_found if log.nil?

    render json: { data: operation_log_json(log) }
  end

  private

  def filtered_scope
    scope = scoped_operation_logs.includes(:actor_user, :actor_external_share, :organization)
    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    scope = scope.where(actor_kind: params[:actor_kind]) if params[:actor_kind].present?
    scope = scope.where(actor_user_id: params[:actor_user_id]) if params[:actor_user_id].present?
    scope = scope.where(actor_external_share_id: params[:actor_external_share_id]) if params[:actor_external_share_id].present?
    scope = scope.where(operation_type: params[:operation_type]) if params[:operation_type].present?
    scope = scope.where(result: params[:result]) if params[:result].present?
    scope = scope.where(target_type: params[:target_type]) if params[:target_type].present?
    scope = scope.where(target_id: params[:target_id]) if params[:target_id].present?
    request_id = request.query_parameters["request_id"]
    scope = scope.where(request_id: request_id) if request_id.present?
    scope = scope.where("operation_logs.occurred_at >= ?", Time.zone.parse(params[:occurred_from])) if params[:occurred_from].present?
    scope = scope.where("operation_logs.occurred_at <= ?", Time.zone.parse(params[:occurred_to])) if params[:occurred_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def operation_log_json(log)
    {
      id: log.id, organization_id: log.organization_id, actor: actor_json(log),
      operation_type: log.operation_type, result: log.result, target: target_json(log),
      change_set: log.change_set, metadata: log.metadata,
      ip_address: log.ip_address, user_agent: log.user_agent, request_id: log.request_id,
      occurred_at: log.occurred_at
    }
  end

  def actor_json(log)
    actor = log.actor_user || log.actor_external_share
    { kind: log.actor_kind, id: actor&.id, display_name: actor_display_name(log, actor) }
  end

  def actor_display_name(log, actor)
    return log.metadata["actor_display_name"] if actor.nil?
    return actor.display_name.presence || actor.email if log.actor_kind == "user"

    "外部共有 ##{actor.id}"
  end

  def target_json(log)
    { type: log.target_type, id: log.target_id, display_name: log.metadata["filename"] || log.metadata["name"] }
  end
end
