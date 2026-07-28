class Api::V1::Admin::FileAccessLogsController < Api::V1::Admin::BaseController
  def index
    scope = scoped_file_access_logs.includes(:user, :organization, :drive_item)
    scope = apply_filters(scope).order(occurred_at: :desc, id: :desc)

    render_collection(scope, method(:file_access_log_json))
  end

  def show
    access_log = scoped_file_access_logs.includes(:user, :organization, :drive_item).find_by(id: params[:id])
    return render_not_found if access_log.nil?

    render json: { data: file_access_log_json(access_log) }
  end

  private

  def apply_filters(scope)
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    scope = scope.where(drive_item_id: params[:drive_item_id]) if params[:drive_item_id].present?
    scope = scope.where(action: request.query_parameters["action"]) if request.query_parameters["action"].present?
    scope = scope.where("drive_item_access_logs.occurred_at >= ?", Time.zone.parse(params[:occurred_from])) if params[:occurred_from].present?
    scope = scope.where("drive_item_access_logs.occurred_at <= ?", Time.zone.parse(params[:occurred_to])) if params[:occurred_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def file_access_log_json(access_log)
    {
      id: access_log.id,
      organization_id: access_log.organization_id,
      organization_name: access_log.organization.name,
      user_id: access_log.user_id,
      user_name: access_log.user&.safe_display_name,
      user_email: access_log.user&.email,
      drive_item_id: access_log.drive_item_id,
      drive_item_name: access_log.drive_item&.filename,
      action: access_log.action,
      occurred_at: access_log.occurred_at,
      ip_address: access_log.ip_address,
      user_agent: access_log.user_agent,
      request_id: access_log.request_id,
      metadata: access_log.metadata
    }
  end
end
