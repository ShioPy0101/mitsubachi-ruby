class Api::V1::Admin::UsersController < Api::V1::Admin::BaseController
  SORT_COLUMNS = {
    "created_at" => :created_at,
    "last_sign_in_at" => :last_sign_in_at,
    "email" => :email,
    "name" => :name
  }.freeze

  def index
    scope = scoped_users.includes(:organization)
    scope = apply_filters(scope)
    scope = scope.order(sort_column => sort_direction, id: :asc)

    render_collection(scope, method(:user_json))
  end

  def show
    user = find_scoped_user
    return render_not_found if user.nil?

    render json: { data: user_json(user) }
  end

  def update
    user = find_scoped_user
    return render_not_found if user.nil?
    return if forbidden_user_management?(user)

    attributes = permitted_user_attributes(user)
    before = user.slice("name", "email", "role", "organization_id")

    return unless validate_user_update!(user, attributes)

    if user.update(attributes)
      action = before["role"] != user.role ? "user.role_change" : "user.update"
      audit_admin_action!(
        action: action,
        target: user,
        organization: user.organization,
        changes: changed_values(before, user.slice("name", "email", "role", "organization_id"))
      )
      render json: { data: user_json(user) }
    else
      render_validation_error(user)
    end
  end

  def suspend
    user = find_scoped_user
    return render_not_found if user.nil?
    return if forbidden_user_management?(user)
    return render_error(:forbidden, "最後の system_admin は停止できません", :forbidden) if last_active_system_admin?(user)

    if user.update(suspended_at: Time.current)
      audit_admin_action!(action: "user.suspend", target: user, organization: user.organization, changes: { suspended_at: [ nil, user.suspended_at ] })
      render json: { data: user_json(user) }
    else
      render_validation_error(user)
    end
  end

  def unsuspend
    user = find_scoped_user
    return render_not_found if user.nil?
    return if forbidden_user_management?(user)

    before = user.suspended_at
    if user.update(suspended_at: nil)
      audit_admin_action!(action: "user.unsuspend", target: user, organization: user.organization, changes: { suspended_at: [ before, nil ] })
      render json: { data: user_json(user) }
    else
      render_validation_error(user)
    end
  end

  private

  def find_scoped_user
    scoped_users.includes(:organization).find_by(id: params[:id])
  end

  def apply_filters(scope)
    if params[:q].present?
      query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s)}%"
      scope = scope.where("users.name ILIKE :query OR users.email ILIKE :query", query: query)
    end

    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    scope = scope.where(role: params[:role]) if params[:role].present? && User.roles.key?(params[:role])
    scope = apply_status_filter(scope)
    scope
  end

  def apply_status_filter(scope)
    case params[:status].to_s
    when "active"
      scope.active
    when "suspended"
      scope.suspended
    else
      scope
    end
  end

  def permitted_user_attributes(user)
    permitted = params.require(:user).permit(:name, :email, :role, :organization_id).to_h

    permitted["organization_id"] = user.organization_id unless system_admin?
    permitted
  end

  def validate_user_update!(user, attributes)
    return fail_user_update!(:validation_error, "role が不正です", :unprocessable_content) if attributes["role"].present? && !User.roles.key?(attributes["role"])
    return fail_user_update!(:forbidden, "system_admin を変更する権限がありません", :forbidden) if !system_admin? && user.system_admin?
    return fail_user_update!(:forbidden, "system_admin へ変更する権限がありません", :forbidden) if !system_admin? && attributes["role"] == "system_admin"
    return fail_user_update!(:forbidden, "別organizationへ移動する権限がありません", :forbidden) if forbidden_organization_change?(user)
    return fail_user_update!(:forbidden, "最後の system_admin は変更できません", :forbidden) if demotes_last_system_admin?(user, attributes)
    return fail_user_update!(:forbidden, "組織の管理者が不在になるため変更できません", :forbidden) if removes_last_organization_admin?(user, attributes)

    true
  end

  def fail_user_update!(code, message, status)
    render_error(code, message, status)
    false
  end

  def forbidden_user_management?(user)
    return false if system_admin?
    return false unless user.system_admin?

    render_error(:forbidden, "system_admin を変更する権限がありません", :forbidden)
    true
  end

  def forbidden_organization_change?(user)
    return false if system_admin?
    return false unless params.dig(:user, :organization_id).present?

    params.dig(:user, :organization_id).to_i != user.organization_id
  end

  def demotes_last_system_admin?(user, attributes)
    return false unless user.system_admin?
    return false if attributes["role"].blank? || attributes["role"] == "system_admin"

    last_active_system_admin?(user)
  end

  def last_active_system_admin?(user)
    user.system_admin? && !User.system_admin.active.where.not(id: user.id).exists?
  end

  def removes_last_organization_admin?(user, attributes)
    return false unless user == current_user
    return false unless user.organization_admin?
    return false if attributes["role"].blank? || attributes["role"] == "organization_admin"

    !User.organization_admin.active.where(organization_id: user.organization_id).where.not(id: user.id).exists?
  end

  def sort_column
    SORT_COLUMNS.fetch(params[:sort].to_s, :created_at)
  end

  def user_json(user)
    {
      id: user.id,
      organization_id: user.organization_id,
      organization_name: user.organization.name,
      email: user.email,
      name: user.name,
      role: user.role,
      suspended: user.suspended?,
      suspended_at: user.suspended_at,
      last_sign_in_at: user.last_sign_in_at,
      created_at: user.created_at,
      updated_at: user.updated_at
    }
  end

  def changed_values(before, after)
    before.each_with_object({}) do |(key, old_value), changes|
      new_value = after[key]
      changes[key] = [ old_value, new_value ] if old_value != new_value
    end
  end
end
