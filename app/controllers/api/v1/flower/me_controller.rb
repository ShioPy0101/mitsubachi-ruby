class Api::V1::Flower::MeController < Api::V1::Flower::BaseController
  def show
    render json: { data: user_json(current_user) }
  end

  private

  def user_json(user)
    {
      id: user.id,
      email: user.email,
      display_name: user.display_name,
      organization_id: user.organization_id,
      organization_name: user.organization.name,
      role: user.role,
      client_type: current_client_type
    }
  end
end
