class ApplicationController < ActionController::API
  include ActionController::Cookies
  include ActionController::RequestForgeryProtection

  protect_from_forgery with: :exception, unless: -> { !Rails.configuration.action_controller.allow_forgery_protection }
  rescue_from ActionController::InvalidAuthenticityToken, with: :render_invalid_authenticity_token
  before_action :reject_suspended_user!

  private

  def authenticate_user!(_options = {})
    return if user_signed_in?

    render_api_error(:unauthorized, "ログインが必要です。", status: :unauthorized)
  end

  def record_audit_event!(action:, actor_user: current_user_or_nil, organization: actor_user&.organization, target: nil, outcome: "success", changes: {}, metadata: {})
    AuditEvents::Recorder.record!(
      action: action,
      actor_user: actor_user,
      organization: organization,
      target: target,
      outcome: outcome,
      changes: changes,
      metadata: { client_type: current_client_type }.merge(metadata),
      request: request
    )
  end

  def current_organization
    current_user&.organization
  end

  def current_client_type
    session[:client_type].presence_in(%w[web flower]) || "web"
  end

  def create_authenticated_session!(user, client_type:)
    reset_session
    sign_in(user)
    session[:client_type] = client_type.presence_in(%w[web flower]) || "web"
  end

  def destroy_authenticated_session!
    sign_out(current_user) if current_user
    reset_session
  end

  def current_user_or_nil
    current_user
  rescue StandardError
    nil
  end

  def reject_suspended_user!
    return unless current_user&.suspended?
    return if devise_controller?
    return if controller_path == "api/v1/sessions"
    return if controller_path == "api/v1/csrf_tokens"

    sign_out(current_user)
    reset_session
    render_api_error(:unauthorized, "このユーザーは停止されています", status: :unauthorized)
  end

  def render_not_found(message = "指定されたリソースが見つかりません")
    render_api_error(:not_found, message, status: :not_found)
  end

  def render_invalid_authenticity_token
    reset_session
    render_api_error(:validation_failed, "認証情報の確認に失敗しました。再読み込みしてからやり直してください", status: :unprocessable_content)
  end

  def render_api_error(code, message, status:, details: {})
    Rails.logger.info("api_error request_id=#{request.request_id} code=#{code} status=#{Rack::Utils.status_code(status)}")
    render json: {
      error: {
        code: code.to_s,
        message: message,
        details: details,
        request_id: request.request_id
      }
    }, status: status
  end

  def render_validation_failed(record_or_messages)
    messages =
      if record_or_messages.respond_to?(:errors)
        record_or_messages.errors.full_messages
      else
        Array(record_or_messages)
      end
    render_api_error(
      :validation_failed,
      messages.first || "入力内容を確認してください",
      status: :unprocessable_content,
      details: { messages: messages }
    )
  end
end
