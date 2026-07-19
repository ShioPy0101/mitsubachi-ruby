class Api::V1::Flower::DeviceAuthorizationApprovalsController < ApplicationController
  before_action :authenticate_user!

  def approve
    result = Flower::DeviceAuthorizations::Approve.new(
      user: current_user,
      user_code: params[:user_code],
      organization_id: params[:organization_id],
      request: request
    ).call
    render_result(result)
  end

  def deny
    result = Flower::DeviceAuthorizations::Deny.new(
      user: current_user,
      user_code: params[:user_code],
      request: request
    ).call
    render_result(result)
  end

  private

  def render_result(result)
    if result.success?
      render json: { status: result.authorization.status }, status: :ok
    else
      render_api_error(result.error_code, result.message, status: result.status)
    end
  end
end
