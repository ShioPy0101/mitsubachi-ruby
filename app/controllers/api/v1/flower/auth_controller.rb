class Api::V1::Flower::AuthController < ApplicationController
  AUTH_REQUEST_IP_LIMIT = Api::V1::EmailAuthenticationsController::AUTH_REQUEST_IP_LIMIT
  AUTH_REQUEST_IP_PERIOD = Api::V1::EmailAuthenticationsController::AUTH_REQUEST_IP_PERIOD
  AUTH_REQUEST_EMAIL_LIMIT = Api::V1::EmailAuthenticationsController::AUTH_REQUEST_EMAIL_LIMIT
  AUTH_REQUEST_EMAIL_PERIOD = Api::V1::EmailAuthenticationsController::AUTH_REQUEST_EMAIL_PERIOD
  VERIFY_REQUEST_IP_LIMIT = Api::V1::EmailAuthenticationsController::VERIFY_REQUEST_IP_LIMIT
  VERIFY_REQUEST_IP_PERIOD = Api::V1::EmailAuthenticationsController::VERIFY_REQUEST_IP_PERIOD

  before_action :authenticate_user!, only: :logout
  before_action :require_flower_client_session!, only: :logout
  before_action :rate_limit_auth_request!, only: %i[create login]
  before_action :rate_limit_verify_request!, only: :verify

  def create
    login
  end

  def login
    result = auth_magic_links.request_login(email: params[:email])
    EmailAuthentications::MagicLinkDelivery.call(
      email: result.email,
      organization: result.organization,
      authentication: result.authentication
    )
    record_flower_event!(
      action: "flower.auth.login_requested",
      actor_user: result.user,
      organization: result.organization,
      target: result.user,
      metadata: { email: result.email }
    )

    render json: { message: "認証リンクを送信しました" }, status: :ok
  rescue Auth::MagicLinks::Failure => error
    record_flower_event!(
      action: "flower.auth.login_failed",
      outcome: "failure",
      metadata: {
        email: normalize_email(params[:email]),
        status: error.status,
        reason: error.message
      }
    )
    render_auth_failure(error)
  end

  def verify
    result = auth_magic_links.verify(params[:token], expected_purpose: "login")
    create_authenticated_session!(result.user, client_type: "flower")
    record_flower_event!(
      action: "flower.auth.login_verified",
      actor_user: result.user,
      organization: result.user.organization,
      target: result.user
    )

    render json: {
      message: "ログインに成功しました",
      user: {
        id: result.user.id,
        email: result.user.email,
        display_name: result.user.display_name
      }
    }, status: :ok
  rescue Auth::MagicLinks::Failure => error
    record_flower_event!(
      action: "flower.auth.login_failed",
      outcome: "failure",
      metadata: { status: error.status, reason: error.message }
    )
    render_auth_failure(error)
  end

  def logout
    user = current_user
    organization = current_organization
    destroy_authenticated_session!
    record_flower_event!(
      action: "flower.auth.logout",
      actor_user: user,
      organization: organization,
      target: user
    )
    head :no_content
  end

  private

  def record_flower_event!(action:, actor_user: current_user_or_nil, organization: actor_user&.organization, target: nil, outcome: "success", metadata: {})
    AuditEvents::Recorder.record!(
      action: action,
      actor_user: actor_user,
      organization: organization,
      target: target,
      outcome: outcome,
      metadata: { client_type: "flower" }.merge(metadata),
      request: request
    )
  end

  def normalize_email(email)
    Auth::MagicLinks.normalize_email(email)
  end

  def auth_magic_links
    @auth_magic_links ||= Auth::MagicLinks.new
  end

  def render_auth_failure(error)
    if error.status == :bad_request
      render_api_error(:invalid_request, error.message, status: error.status)
    else
      render_api_error(:unauthenticated, "認証に失敗しました。", status: error.status)
    end
  end

  def rate_limit_auth_request!
    checks = [
      rate_limit_result("auth-ip", request.remote_ip, AUTH_REQUEST_IP_LIMIT, AUTH_REQUEST_IP_PERIOD)
    ]
    normalized_email = normalize_email(params[:email])
    checks << rate_limit_result("auth-email", normalized_email, AUTH_REQUEST_EMAIL_LIMIT, AUTH_REQUEST_EMAIL_PERIOD) if normalized_email.present?
    reject_rate_limited_request!(checks)
  end

  def rate_limit_verify_request!
    reject_rate_limited_request!([
      rate_limit_result("auth-verify-ip", request.remote_ip, VERIFY_REQUEST_IP_LIMIT, VERIFY_REQUEST_IP_PERIOD)
    ])
  end

  def rate_limit_result(namespace, key, limit, period)
    Security::RateLimiter.new(namespace: namespace, key: key, limit: limit, period: period).call
  end

  def reject_rate_limited_request!(checks)
    limited_result = checks.find { |result| !result.allowed? }
    return if limited_result.nil?

    response.headers["Retry-After"] = limited_result.retry_after.to_s
    render json: { error: "リクエスト数が上限を超えました。しばらく待ってから再試行してください" }, status: :too_many_requests
  end

  def require_flower_client_session!
    return if performed?
    return if current_client_type == "flower"

    render_api_error(:unauthorized, "flowerでのログインが必要です。", status: :unauthorized)
  end
end
