class Api::V1::MeController < ApplicationController
  before_action :authenticate_user!

  def show
    render json: { data: user_json(current_user) }
  end

  private

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
end
