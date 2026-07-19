class Api::V1::Flower::MeController < Api::V1::Flower::BaseController
  def show
    render json: {
      user: {
        id: current_user.id.to_s,
        name: current_user.safe_display_name
      },
      organization: {
        id: current_organization.id.to_s,
        name: current_organization.name
      },
      scopes: current_scopes
    }
  end
end
