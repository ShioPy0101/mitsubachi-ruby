class Api::V1::Flower::DeviceAuthorizationsController < ApplicationController
  skip_forgery_protection

  def create
    result = Flower::DeviceAuthorizations::Create.new(
      client_name: params[:client_name],
      client_version: params[:client_version],
      device_name: params[:device_name],
      request: request
    ).call

    unless result.success?
      render_flower_error(result.error_code, result.message, status: result.status)
      return
    end

    render json: {
      device_code: result.device_code,
      user_code: result.user_code,
      verification_uri: flower_activation_url,
      verification_uri_complete: flower_activation_url(user_code: result.user_code),
      expires_in: (result.authorization.expires_at - Time.current).to_i,
      interval: result.authorization.interval_seconds
    }, status: :ok
  end

  def show
    authorization = FlowerDeviceAuthorization.find_by(
      device_code_digest: Flower::DeviceAuthorizations::Code.device_code_digest(params[:device_code])
    )
    return render_flower_error("invalid_grant", "Device code is invalid.", status: :not_found) if authorization.nil?

    render json: {
      status: authorization.expired? && authorization.pending? ? "expired" : authorization.status,
      expires_at: authorization.expires_at.iso8601(3),
      interval: authorization.interval_seconds
    }
  end

  private

  def flower_activation_url(user_code: nil)
    url = "#{flower_frontend_url}#{Flower::DeviceAuthorizations::Create::VERIFICATION_PATH}"
    return url if user_code.blank?

    "#{url}?#{ { user_code: user_code }.to_query }"
  end

  def flower_frontend_url
    origin = ENV.fetch("FLOWER_FRONTEND_URL") do
      ENV.fetch("FRONTEND_URL") do
        Rails.env.development? || Rails.env.test? ? "http://localhost:5173" : request.base_url
      end
    end
    origin.to_s.delete_suffix("/")
  end

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
