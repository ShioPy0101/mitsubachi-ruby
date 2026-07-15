class Api::V1::Admin::AuditLogsController < Api::V1::Admin::BaseController
  def index
    scope = scoped_admin_audit_logs.includes(:actor_user, :organization)
    scope = apply_filters(scope).order(created_at: :desc, id: :desc)

    render_collection(scope, method(:audit_log_json))
  end

  def show
    audit_log = scoped_admin_audit_logs.includes(:actor_user, :organization).find_by(id: params[:id])
    return render_not_found if audit_log.nil?

    render json: { data: audit_log_json(audit_log) }
  end

  private

  def apply_filters(scope)
    scope = scope.where(actor_user_id: params[:actor_user_id]) if params[:actor_user_id].present?
    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    scope = scope.where(action: request.query_parameters["action"]) if request.query_parameters["action"].present?
    scope = scope.where(target_type: params[:target_type]) if params[:target_type].present?
    scope = scope.where("admin_audit_logs.created_at >= ?", Time.zone.parse(params[:created_from])) if params[:created_from].present?
    scope = scope.where("admin_audit_logs.created_at <= ?", Time.zone.parse(params[:created_to])) if params[:created_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def audit_log_json(audit_log)
    {
      id: audit_log.id,
      actor_user_id: audit_log.actor_user_id,
      actor_email: audit_log.actor_user.email,
      organization_id: audit_log.organization_id,
      organization_name: audit_log.organization.name,
      action: audit_log.action,
      target_type: audit_log.target_type,
      target_id: audit_log.target_id,
      change_set: audit_log.change_set,
      ip_address: audit_log.ip_address,
      user_agent: audit_log.user_agent,
      created_at: audit_log.created_at
    }
  end
end
