class Api::V1::Admin::OrganizationInvitesController < Api::V1::Admin::BaseController
  DEFAULT_TTL = 7.days
  MAX_TTL = 30.days

  def create
    organization = invite_organization
    return render_not_found if organization.nil?
    return render_error(:forbidden, "この操作を実行する権限がありません", :forbidden) unless can_create_invite_for?(organization)

    invite = organization.organization_invites.new(invite_params)
    invite.code = generate_invite_code
    invite.expires_at ||= DEFAULT_TTL.from_now

    if invite.expires_at > MAX_TTL.from_now
      return render_error(:validation_error, "expires_at は30日以内を指定してください", :unprocessable_content)
    end

    if invite.save
      audit_admin_action!(
        action: "organization_invite.create",
        target: invite,
        organization: organization,
        changes: {
          code: [ nil, invite.code ],
          expires_at: [ nil, invite.expires_at ]
        }
      )
      render json: { data: invite_json(invite) }, status: :created
    else
      render json: { errors: invite.errors.full_messages }, status: :unprocessable_content
    end
  end

  private

  def invite_organization
    requested_organization_id = params.dig(:organization_invite, :organization_id)

    if system_admin?
      Organization.find_by(id: requested_organization_id || current_user.organization_id)
    elsif requested_organization_id.present? && requested_organization_id.to_i != current_user.organization_id
      Organization.find_by(id: requested_organization_id)
    else
      current_user.organization
    end
  end

  def can_create_invite_for?(organization)
    system_admin? || organization.id == current_user.organization_id
  end

  def invite_params
    params.fetch(:organization_invite, ActionController::Parameters.new).permit(:expires_at)
  end

  def generate_invite_code
    loop do
      code = SecureRandom.urlsafe_base64(18)
      return code unless OrganizationInvite.exists?(code: code)
    end
  end

  def invite_json(invite)
    {
      id: invite.id,
      organization_id: invite.organization_id,
      organization_name: invite.organization.name,
      code: invite.code,
      expires_at: invite.expires_at,
      used_at: invite.used_at,
      used_by_user_id: invite.used_by_user_id,
      stand_by_at: invite.stand_by_at,
      stand_by_user_id: invite.stand_by_user_id,
      created_at: invite.created_at,
      updated_at: invite.updated_at
    }
  end
end
