class Api::V1::EmailAuthenticationsController < ApplicationController
  REGISTRATION_STAND_BY_WINDOW = 15.minutes
  AUTHENTICATION_TOKEN_TTL = 15.minutes
  AUTH_REQUEST_IP_LIMIT = 20
  AUTH_REQUEST_IP_PERIOD = 10.minutes
  AUTH_REQUEST_EMAIL_LIMIT = 5
  AUTH_REQUEST_EMAIL_PERIOD = 15.minutes
  VERIFY_REQUEST_IP_LIMIT = 60
  VERIFY_REQUEST_IP_PERIOD = 10.minutes

  AuthFailure = Class.new(StandardError) do
    attr_reader :message, :status

    def initialize(message, status)
      @message = message
      @status = status
      super(message)
    end
  end

  VerificationResult = Data.define(:user, :organization_invite)
  RequestResult = Data.define(:email, :token, :user, :organization, :organization_invite)

  before_action :rate_limit_auth_request!, only: %i[create login]
  before_action :rate_limit_verify_request!, only: :verify

  def create
    email = normalize_email(params[:email])
    invite_code = params[:invite_code]
    display_name = normalize_display_name(params[:display_name])

    return render_error("email は必須です", :bad_request) if email.blank?
    return render_error("invite_code は必須です", :bad_request) if invite_code.blank?
    return render_error("表示名は50文字以内で入力してください", :bad_request) if display_name&.length.to_i > 50

    result = build_registration_request!(email:, invite_code:, display_name:)
    deliver_magic_link(result)
    record_audit_event!(
      action: "auth.registration_link.create",
      actor_user: result.user,
      organization: result.organization,
      target: result.organization_invite,
      metadata: { email: result.email }
    )

    render json: { message: "認証リンクを送信しました" }, status: :ok
  rescue AuthFailure => error
    record_auth_failure!("auth.registration_link.create", email: email, error: error)
    render_error(error.message, error.status)
  end

  def login
    email = normalize_email(params[:email])

    return render_error("email は必須です", :bad_request) if email.blank?

    result = build_login_request!(email:)
    deliver_magic_link(result)
    record_audit_event!(
      action: "auth.login_link.create",
      actor_user: result.user,
      organization: result.organization,
      target: result.user,
      metadata: { email: result.email }
    )

    render json: { message: "認証リンクを送信しました" }, status: :ok
  rescue AuthFailure => error
    record_auth_failure!("auth.login_link.create", email: email, error: error)
    render_error(error.message, error.status)
  end

  def verify
    token = params[:token]

    return render_error("token は必須です", :bad_request) if token.blank?

    result = verify_token!(token)
    sign_in_verified_user(result.user)
    record_audit_event!(
      action: result.organization_invite.present? ? "auth.registration.verify" : "auth.login.verify",
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
  rescue AuthFailure => error
    record_auth_failure!("auth.verify", error: error)
    render_error(error.message, error.status)
  end

  private

  def build_registration_request!(email:, invite_code:, display_name:)
    raw_token = SecureRandom.urlsafe_base64(32)
    hashed_token = Digest::SHA256.hexdigest(raw_token)
    now = Time.current

    stand_by_user = nil
    invite = nil

    ActiveRecord::Base.transaction do
      invite = OrganizationInvite.lock.find_by(code: invite_code)
      validate_invite_for_registration!(invite, now)

      existing_user = find_user_by_email(email)
      existing_user&.lock!
      validate_user_for_registration!(existing_user, invite)
      validate_display_name_for_registration!(display_name, invite, existing_user)
      clear_stale_stand_by!(existing_user, now) if existing_user.present?

      stand_by_user = existing_user || User.new(email: email)
      stand_by_user.organization = invite.organization
      stand_by_user.display_name = display_name if display_name.present?
      stand_by_user.password = SecureRandom.base64(32) unless stand_by_user.persisted?
      stand_by_user.save!

      expire_active_registration_authentications!(invite, now)

      invite.update!(
        stand_by_at: now,
        stand_by_user: stand_by_user
      )

      EmailAuthentication.create!(
        email: email,
        token: hashed_token,
        expires_at: AUTHENTICATION_TOKEN_TTL.from_now,
        organization_invite: invite
      )
    end

    RequestResult.new(email, raw_token, stand_by_user, invite.organization, invite)
  end

  def build_login_request!(email:)
    raw_token = SecureRandom.urlsafe_base64(32)
    hashed_token = Digest::SHA256.hexdigest(raw_token)
    now = Time.current

    user = nil

    ActiveRecord::Base.transaction do
      user = find_user_by_email(email)
      validate_user_for_login!(user)

      user.lock!
      user.reload
      validate_user_for_login!(user)

      expire_active_login_authentications!(email, now)

      EmailAuthentication.create!(
        email: email,
        token: hashed_token,
        expires_at: AUTHENTICATION_TOKEN_TTL.from_now
      )
    end

    RequestResult.new(email, raw_token, user, user.organization, nil)
  end

  def verify_token!(raw_token)
    hashed_token = Digest::SHA256.hexdigest(raw_token)
    now = Time.current
    verified_user = nil
    failure = nil
    authentication = nil

    ActiveRecord::Base.transaction do
      authentication = EmailAuthentication.lock.find_by(token: hashed_token)
      validate_authentication!(authentication, now)

      user = find_user_by_email(authentication.email)
      validate_user_presence!(user)
      user.lock!
      user.reload

      if user.suspended?
        mark_authentication_used!(authentication, now)
        failure = AuthFailure.new("このユーザーは停止されています", :unauthorized)
        next
      end

      invite = authentication.organization_invite
      if invite.nil?
        reject_provisional_login_user!(user)
        mark_authentication_used!(authentication, now)
        verified_user = user
        next
      end

      invite.lock!
      invite.reload
      validate_invite_for_verification!(invite, user, now)

      invite.update!(
        used_at: now,
        used_by_user: user,
        stand_by_at: nil,
        stand_by_user: nil
      )
      mark_authentication_used!(authentication, now)
      verified_user = user
    end

    raise failure if failure

    VerificationResult.new(verified_user, authentication.organization_invite)
  end

  def validate_invite_for_registration!(invite, now)
    raise AuthFailure.new("invite_code が正しくありません", :unauthorized) if invite.nil?
    raise AuthFailure.new("invite_code の有効期限が切れています", :unauthorized) if invite.expires_at <= now
    raise AuthFailure.new("この invite_code は既に使用されています", :unauthorized) if invite.used_at.present?
    raise AuthFailure.new("この invite_code は現在検証中です", :conflict) if invite_stand_by_active?(invite, now)
  end

  def validate_user_for_registration!(user, invite)
    return if user.nil?
    raise AuthFailure.new("このユーザーは停止されています", :unauthorized) if user.suspended?
    raise AuthFailure.new("このメールアドレスはすでに登録されています", :conflict) unless provisional_user?(user)
    raise AuthFailure.new("このメールアドレスは現在検証中です", :conflict) if active_stand_by_invite_for(user).present?
    raise AuthFailure.new("このメールアドレスはすでに登録されています", :conflict) if user.organization_id != invite.organization_id && !stale_provisional_user?(user)
  end

  def validate_user_for_login!(user)
    validate_user_presence!(user)
    raise AuthFailure.new("このユーザーは停止されています", :unauthorized) if user.suspended?
    reject_provisional_login_user!(user)
  end

  def validate_display_name_for_registration!(display_name, invite, existing_user)
    return if display_name.blank?

    scope = invite.organization.users.where(display_name: display_name)
    scope = scope.where.not(id: existing_user.id) if existing_user.present?
    return unless scope.exists?

    raise AuthFailure.new("この表示名は既に使用されています", :conflict)
  end

  def validate_user_presence!(user)
    raise AuthFailure.new("ユーザーが存在しません", :unauthorized) if user.nil?
  end

  def reject_provisional_login_user!(user)
    raise AuthFailure.new("登録用リンクでメール認証を完了してください", :unauthorized) if provisional_user?(user)
  end

  def validate_authentication!(authentication, now)
    raise AuthFailure.new("リンクが正しくありません", :unauthorized) if authentication.nil?
    authentication.reload
    raise AuthFailure.new("このリンクは既に使用されています", :unauthorized) if authentication.used_at.present?
    raise AuthFailure.new("リンクの有効期限が切れています", :unauthorized) if authentication.expires_at <= now
  end

  def validate_invite_for_verification!(invite, user, now)
    raise AuthFailure.new("この invite_code は既に使用されています", :unauthorized) if invite.used_at.present?
    raise AuthFailure.new("この invite_code の有効期限が切れています", :unauthorized) if invite.expires_at <= now
    raise AuthFailure.new("このユーザーは stand-by ではありません", :unauthorized) if invite.stand_by_user_id != user.id
    raise AuthFailure.new("この invite_code は現在検証中ではありません", :unauthorized) unless invite_stand_by_active?(invite, now)
  end

  def mark_authentication_used!(authentication, now)
    authentication.update!(used_at: now)
  end

  def expire_active_login_authentications!(email, now)
    EmailAuthentication
      .where(organization_invite_id: nil, used_at: nil)
      .where("expires_at > ?", now)
      .where("LOWER(email) = ?", email.downcase)
      .update_all(used_at: now, updated_at: now)
  end

  def expire_active_registration_authentications!(invite, now)
    invite
      .email_authentications
      .where(used_at: nil)
      .where("expires_at > ?", now)
      .update_all(used_at: now, updated_at: now)
  end

  def deliver_magic_link(result)
    EmailAuthenticationMailer
      .with(email: result.email, token: result.token)
      .send_magic_link
      .deliver_later
  end

  def sign_in_verified_user(user)
    reset_session
    sign_in(user)
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
    email.to_s.strip.downcase
  end

  def normalize_display_name(display_name)
    display_name.to_s.strip.presence
  end

  def find_user_by_email(email)
    User.find_by("LOWER(email) = ?", normalize_email(email))
  end

  def invite_stand_by_active?(invite, now = Time.current)
    invite.stand_by_user.present? &&
      invite.stand_by_at.present? &&
      invite.stand_by_at > REGISTRATION_STAND_BY_WINDOW.ago(now)
  end

  def provisional_user?(user)
    OrganizationInvite.where(stand_by_user: user, used_at: nil).exists? &&
      !OrganizationInvite.where(used_by_user: user).exists?
  end

  def stale_provisional_user?(user)
    OrganizationInvite
      .where(stand_by_user: user, used_at: nil)
      .where("stand_by_at IS NULL OR stand_by_at <= ?", REGISTRATION_STAND_BY_WINDOW.ago)
      .exists?
  end

  def active_stand_by_invite_for(user)
    OrganizationInvite
      .where(stand_by_user: user, used_at: nil)
      .where("stand_by_at > ?", REGISTRATION_STAND_BY_WINDOW.ago)
      .first
  end

  def clear_stale_stand_by!(user, now = Time.current)
    OrganizationInvite
      .where(stand_by_user: user, used_at: nil)
      .where("stand_by_at IS NULL OR stand_by_at <= ?", REGISTRATION_STAND_BY_WINDOW.ago(now))
      .update_all(stand_by_user_id: nil, stand_by_at: nil, updated_at: now)
  end

  def rate_limit_auth_request!
    checks = [
      rate_limit_result("auth-ip", request.remote_ip, AUTH_REQUEST_IP_LIMIT, AUTH_REQUEST_IP_PERIOD)
    ]
    normalized_email = normalize_email(params[:email])
    if normalized_email.present?
      checks << rate_limit_result("auth-email", normalized_email, AUTH_REQUEST_EMAIL_LIMIT, AUTH_REQUEST_EMAIL_PERIOD)
    end

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
