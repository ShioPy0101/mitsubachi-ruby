class Api::V1::Admin::DriveItemAccessLogsController < Api::V1::Admin::BaseController
  def index
    render_collection(filtered_scope.order(occurred_at: :desc, id: :desc), method(:access_log_json))
  end

  def show
    log = scoped_file_access_logs.includes(:user, :external_share, :organization, :drive_item).find_by(id: params[:id])
    return render_not_found if log.nil?

    render json: { data: access_log_json(log) }
  end

  private

  def filtered_scope
    scope = scoped_file_access_logs.includes(:user, :external_share, :organization, :drive_item)
    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    %i[user_id external_share_id drive_item_id ip_address].each do |key|
      scope = scope.where(key => params[key]) if params[key].present?
    end
    action = request.query_parameters["action"]
    scope = scope.where(action: action) if action.present?
    request_id = request.query_parameters["request_id"]
    scope = scope.where(request_id: request_id) if request_id.present?
    scope = scope.where("drive_item_access_logs.metadata ->> 'filename' ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:filename])}%") if params[:filename].present?
    scope = scope.where("drive_item_access_logs.occurred_at >= ?", Time.zone.parse(params[:occurred_from])) if params[:occurred_from].present?
    scope = scope.where("drive_item_access_logs.occurred_at <= ?", Time.zone.parse(params[:occurred_to])) if params[:occurred_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def access_log_json(log)
    {
      id: log.id, actor_kind: log.actor_kind, user_id: log.user_id,
      external_share_id: log.external_share_id, organization_id: log.organization_id,
      drive_item_id: log.drive_item_id, action: log.action, occurred_at: log.occurred_at,
      ip_address: log.ip_address, user_agent: log.user_agent, request_id: log.request_id,
      metadata: log.metadata
    }
  end
end
