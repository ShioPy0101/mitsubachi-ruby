class Api::V1::Admin::AuditEventsController < Api::V1::Admin::BaseController
  def index
    scope = scoped_audit_events.includes(:actor_user, :organization)
    scope = apply_filters(scope).order(occurred_at: :desc, id: :desc)

    render_collection(scope, method(:audit_event_json))
  end

  def show
    audit_event = scoped_audit_events.includes(:actor_user, :organization).find_by(id: params[:id])
    return render_not_found if audit_event.nil?

    render json: { data: audit_event_json(audit_event) }
  end

  private

  def apply_filters(scope)
    scope = scope.where(actor_user_id: params[:actor_user_id]) if params[:actor_user_id].present?
    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    scope = scope.where(action: request.query_parameters["action"]) if request.query_parameters["action"].present?
    scope = scope.where(outcome: params[:outcome]) if params[:outcome].present? && AuditEvent::OUTCOMES.include?(params[:outcome])
    scope = scope.where(target_type: params[:target_type]) if params[:target_type].present?
    scope = scope.where("audit_events.occurred_at >= ?", Time.zone.parse(params[:occurred_from])) if params[:occurred_from].present?
    scope = scope.where("audit_events.occurred_at <= ?", Time.zone.parse(params[:occurred_to])) if params[:occurred_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def audit_event_json(audit_event)
    {
      id: audit_event.id,
      organization_id: audit_event.organization_id,
      organization_name: audit_event.organization&.name,
      actor_user_id: audit_event.actor_user_id,
      actor_email: audit_event.actor_user&.email,
      action: audit_event.action,
      outcome: audit_event.outcome,
      target_type: audit_event.target_type,
      target_id: audit_event.target_id,
      change_set: audit_event.change_set,
      metadata: audit_event.metadata,
      ip_address: audit_event.ip_address,
      user_agent: audit_event.user_agent,
      request_id: audit_event.request_id,
      occurred_at: audit_event.occurred_at,
      created_at: audit_event.created_at
    }
  end
end
