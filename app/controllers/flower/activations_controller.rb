class Flower::ActivationsController < ApplicationController
  before_action :authenticate_user!

  def show
    render json: {
      user_code: params[:user_code].to_s,
      organizations: [
        {
          id: current_user.organization_id.to_s,
          name: current_user.organization.name
        }
      ]
    }
  end
end
