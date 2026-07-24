class Api::V1::GroupsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_current_organization, if: :organization_path_scope?

  def show
    organization = current_organization

    render json: {
      data: {
        id: organization.id,
        name: organization.name,
        description: organization.description,
        member_count: organization.users.count,
        current_user_role: current_membership&.role || current_user.role,
        members: organization.organization_memberships.active.includes(:user).order("users.display_name", "users.name", "users.id").references(:user).map { |membership| member_json(membership) }
      }
    }
  end

  def update
    return render_forbidden unless current_user.system_admin? || current_membership&.organization_admin?

    organization = current_organization
    before = organization.slice("name", "description")

    if organization.update(group_params)
      record_audit_event!(
        action: "group.update",
        target: organization,
        organization: organization,
        changes: changed_values(before, organization.slice("name", "description"))
      )
      render json: { data: { id: organization.id, name: organization.name, description: organization.description } }
    else
      render_validation_failed(organization)
    end
  end

  private

  def member_json(membership)
    user = membership.user
    {
      id: user.id,
      display_name: user.safe_display_name,
      role: membership.role,
      joined_at: membership.joined_at || user.created_at,
      suspended: user.suspended?
    }
  end

  def group_params
    params.require(:group).permit(:name, :description)
  end

  def render_forbidden
    render_api_error(:forbidden, "この操作を実行する権限がありません", status: :forbidden)
  end

  def changed_values(before, after)
    before.each_with_object({}) do |(key, old_value), changes|
      new_value = after[key]
      changes[key] = [ old_value, new_value ] if old_value != new_value
    end
  end
end
