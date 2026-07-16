class ApplicationController < ActionController::API
  include ActionController::Cookies
  include ActionController::RequestForgeryProtection

  protect_from_forgery with: :exception, unless: -> { !Rails.configuration.action_controller.allow_forgery_protection }
  rescue_from ActionController::InvalidAuthenticityToken, with: :render_invalid_authenticity_token
  before_action :reject_suspended_user!

  private

  def reject_suspended_user!
    return unless current_user&.suspended?
    return if devise_controller?
    return if controller_path == "api/v1/sessions"
    return if controller_path == "api/v1/csrf_tokens"

    sign_out(current_user)
    reset_session
    render json: { error: "このユーザーは停止されています" }, status: :unauthorized
  end

  def render_not_found(message = "指定されたリソースが見つかりません")
    render json: { error: message }, status: :not_found
  end

  def render_invalid_authenticity_token
    reset_session
    render json: { error: "CSRF token が無効です" }, status: :unprocessable_entity
  end
end
