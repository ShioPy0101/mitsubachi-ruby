class Api::V1::EmailAuthenticationsController < ApplicationController
  AUTH_REQUEST_IP_LIMIT = 20
  AUTH_REQUEST_IP_PERIOD = 10.minutes
  AUTH_REQUEST_EMAIL_LIMIT = 5
  AUTH_REQUEST_EMAIL_PERIOD = 15.minutes
  VERIFY_REQUEST_IP_LIMIT = 60
  VERIFY_REQUEST_IP_PERIOD = 10.minutes

  before_action :rate_limit_auth_request!, only: %i[create login]
  before_action :rate_limit_verify_request!, only: %i[verify verify_registration verify_login]

  def create
    result = auth_magic_links.request_registration(
      email: params[:email],
      invite_code: params[:invite_code],
      display_name: params[:display_name]
    )
    deliver_magic_link(result)
    record_audit_event!(
      action: "auth.registration_link.create",
      actor_user: result.user,
      organization: result.organization,
      target: result.organization_invite,
      metadata: { email: result.email }
    )

    render json: { message: "認証リンクを送信しました" }, status: :ok
  rescue Auth::MagicLinks::Failure => error
    record_auth_failure!("auth.registration_link.create", email: normalize_email(params[:email]), error: error)
    render_error(error.message, error.status)
  end

  def login
    result = auth_magic_links.request_login(email: params[:email])
    deliver_magic_link(result)
    record_audit_event!(
      action: "auth.login_link.create",
      actor_user: result.user,
      organization: result.organization,
      target: result.user,
      metadata: { email: result.email }
    )

    render json: { message: "認証リンクを送信しました" }, status: :ok
  rescue Auth::MagicLinks::Failure => error
    record_auth_failure!("auth.login_link.create", email: normalize_email(params[:email]), error: error)
    render_error(error.message, error.status)
  end

  def verify
    render_verified_user(auth_magic_links.verify(params[:token]))
  rescue Auth::MagicLinks::Failure => error
    record_auth_failure!("auth.verify", error: error)
    render_error(error.message, error.status)
  end

  def verify_registration
    verify_for_purpose!("registration")
  end

  def verify_login
    verify_for_purpose!("login")
  end

  private

  def verify_for_purpose!(purpose)
    render_verified_user(auth_magic_links.verify(params[:token], expected_purpose: purpose))
  rescue Auth::MagicLinks::Failure => error
    record_auth_failure!("auth.#{purpose}.verify", error: error)
    render_error(error.message, error.status)
  end

  def deliver_magic_link(result)
    EmailAuthentications::MagicLinkDelivery.call(
      email: result.email,
      organization: result.organization,
      authentication: result.authentication
    )
  end

  def render_verified_user(result)
    create_authenticated_session!(result.user, client_type: "web")
    record_audit_event!(
      action: "auth.#{result.purpose}.verify",
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
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end

  def record_auth_failure!(action, email: nil, error:)
    record_audit_event!(
      action: action,
      outcome: "failure",
      metadata: {
        email: email,
        status: error.status,
        reason: error.message
      }
    )
  end

  def normalize_email(email)
    Auth::MagicLinks.normalize_email(email)
  end

  def auth_magic_links
    @auth_magic_links ||= Auth::MagicLinks.new
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
    Security::RateLimiter.new(
      namespace: namespace,
      key: key,
      limit: limit,
      period: period
    ).call
  end

  def reject_rate_limited_request!(checks)
    limited_result = checks.find { |result| !result.allowed? }
    return if limited_result.nil?

    response.headers["Retry-After"] = limited_result.retry_after.to_s
    render json: { error: "リクエスト数が上限を超えました。しばらく待ってから再試行してください" }, status: :too_many_requests
  end
end
