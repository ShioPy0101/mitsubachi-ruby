class Api::V1::Admin::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

  private

  MAX_PER_PAGE = 100
  DEFAULT_PER_PAGE = 20

  def require_admin!
    return if current_user.system_admin? || current_user.organization_admin?

    render_error(:forbidden, "この操作を実行する権限がありません", :forbidden)
  end

  def system_admin?
    current_user.system_admin?
  end

  def scoped_organizations
    return Organization.all if system_admin?

    Organization.where(id: current_user.organization_id)
  end

  def all_drive_error_sample
    DriveItem.find(params[:id])
  end

  def scoped_users
    return User.all if system_admin?

    User.where(organization_id: current_user.organization_id)
  end

  def scoped_drive_items
    return DriveItem.all if system_admin?

    DriveItem.where(organization_id: current_user.organization_id)
  end

  def scoped_admin_audit_logs
    return AdminAuditLog.all if system_admin?

    AdminAuditLog.where(organization_id: current_user.organization_id)
  end

  def scoped_audit_events
    return AuditEvent.all if system_admin?

    AuditEvent.where(organization_id: current_user.organization_id)
  end

  def paginate(scope)
    page = positive_integer(params[:page], 1)
    per_page = [ positive_integer(params[:per_page], DEFAULT_PER_PAGE), MAX_PER_PAGE ].min
    total_count = scope.count
    total_pages = total_count.zero? ? 1 : (total_count.to_f / per_page).ceil

    [
      scope.offset((page - 1) * per_page).limit(per_page),
      {
        current_page: page,
        per_page: per_page,
        total_pages: total_pages,
        total_count: total_count
      }
    ]
  end

  def positive_integer(value, default)
    integer = value.to_i
    integer.positive? ? integer : default
  end

  def sort_direction
    params[:direction].to_s.downcase == "asc" ? :asc : :desc
  end

  def render_collection(scope, serializer)
    records, meta = paginate(scope)
    render json: { data: records.map { |record| serializer.call(record) }, meta: meta }
  end

  def render_error(code, message, status, details: nil)
    error = { code: code, message: message }
    error[:details] = details if details.present?

    render json: { error: error }, status: status
  end

  def render_not_found(message = "対象が見つかりません")
    render_error(:not_found, message, :not_found)
  end

  def render_validation_error(record)
    render_error(:validation_error, "入力内容を確認してください", :unprocessable_entity, details: record.errors.to_hash)
  end

  def render_record_invalid(error)
    render_validation_error(error.record)
  end

  def audit_admin_action!(action:, target:, organization:, changes: {})
    AdminAuditLog.create!(
      actor_user: current_user,
      organization: organization,
      action: action,
      target_type: target.class.name,
      target_id: target.id,
      change_set: sanitize_audit_changes(changes),
      ip_address: request.remote_ip,
      user_agent: request.user_agent.to_s
    )
    record_audit_event!(
      action: action,
      target: target,
      organization: organization,
      changes: changes
    )
  end

  def record_audit_event!(action:, target: nil, organization: current_user&.organization, outcome: "success", changes: {}, metadata: {})
    AuditEvents::Recorder.record!(
      action: action,
      actor_user: current_user,
      organization: organization,
      target: target,
      outcome: outcome,
      changes: changes,
      metadata: metadata,
      request: request
    )
  end

  def sanitize_audit_changes(changes)
    changes.deep_stringify_keys.except(
      "encrypted_password",
      "password",
      "reset_password_token",
      "remember_created_at"
    )
  end
end
