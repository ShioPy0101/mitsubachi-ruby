class Api::V1::OrganizationInvitationsController < ApplicationController
  skip_before_action :reject_suspended_user!, only: :show
  before_action :authenticate_user!, only: :accept

  def show
    invite = OrganizationInvite.includes(:organization, :invited_by_user).find_by(code: params[:token])
    return render_api_error(:invalid_invitation, "招待が見つかりません", status: :not_found) if invite.nil?

    render json: { invitation: invitation_json(invite) }, status: :ok
  end

  def accept
    result = OrganizationInvitations::AcceptanceService.call(token: params[:token], user: current_user)
    record_operation!(
      operation_type: "organization.membership_created",
      actor_user: current_user,
      organization: result.invite.organization,
      target: result.membership,
      changes: {
        user_id: [ nil, current_user.id ],
        role: [ nil, result.membership.role ],
        status: [ nil, result.membership.status ]
      },
      metadata: { invitation_id: result.invite.id }
    )

    render json: {
      message: "組織に参加しました",
      membership: membership_json(result.membership)
    }, status: :ok
  rescue OrganizationInvitations::AcceptanceService::Failure => error
    render_api_error(error.code, error.message, status: error.status)
  end

  private

  def invitation_json(invite)
    {
      token: invite.code,
      organization: {
        id: invite.organization_id,
        name: invite.organization&.name
      },
      invited_by: invite.invited_by_user && {
        id: invite.invited_by_user.id,
        display_name: invite.invited_by_user.safe_display_name,
        email: invite.invited_by_user.email
      },
      email: invite.email,
      role: invite.role,
      expires_at: invite.expires_at,
      accepted_at: invite.used_at,
      revoked_at: invite.revoked_at
    }
  end

  def membership_json(membership)
    {
      organization: {
        id: membership.organization_id,
        name: membership.organization.name
      },
      role: membership.role,
      status: membership.status,
      joined_at: membership.joined_at
    }
  end
end
