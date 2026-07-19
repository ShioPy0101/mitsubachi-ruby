class Api::V1::Flower::TokensController < ApplicationController
  skip_forgery_protection

  def create
    result = Flower::Tokens::Exchange.new(
      grant_type: params[:grant_type],
      device_code: params[:device_code],
      request: request
    ).call

    unless result.success?
      render_flower_error(result.error_code, result.message, status: result.status)
      return
    end

    render json: {
      token_type: "Bearer",
      access_token: result.access_token,
      expires_in: (result.token.expires_at - Time.current).to_i,
      scope: result.token.scopes.join(" "),
      organization_id: result.token.organization_id.to_s
    }, status: :ok
  end

  private

  def render_flower_error(code, message, status:)
    render json: {
      error: {
        code: code,
        message: message,
        request_id: request.request_id
      }
    }, status: status
  end
end
