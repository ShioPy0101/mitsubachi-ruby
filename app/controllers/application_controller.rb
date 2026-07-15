class ApplicationController < ActionController::API
  include ActionController::Cookies
  include ActionController::RequestForgeryProtection

  protect_from_forgery with: :exception, unless: -> { !Rails.configuration.action_controller.allow_forgery_protection }

  private

  def render_not_found(message = "指定されたリソースが見つかりません")
    render json: { error: message }, status: :not_found
  end
end
