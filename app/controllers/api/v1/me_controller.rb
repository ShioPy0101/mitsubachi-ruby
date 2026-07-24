class Api::V1::MeController < ApplicationController
  EMAIL_CHANGE_REQUEST_IP_LIMIT = 20
  EMAIL_CHANGE_REQUEST_EMAIL_LIMIT = 5
  EMAIL_CHANGE_REQUEST_PERIOD = 15.minutes

  before_action :authenticate_user!, except: :verify_email_change
  before_action :rate_limit_email_change_request!, only: :request_email_change

  def show
    render json: { data: user_json(current_user) }
  end

  def update
    before_display_name = current_user.display_name
    current_user.assign_attributes(update_params)

    if current_user.display_name.blank?
      current_user.errors.add(:display_name, "を入力してください")
      return render_validation_failed(current_user)
    end

    if current_user.save
      record_audit_event!(
        action: "user.profile.update",
        target: current_user,
        changes: { display_name: [ before_display_name, current_user.display_name ] }
      ) if before_display_name != current_user.display_name

      render json: { data: user_json(current_user) }
    else
      render_validation_failed(current_user)
    end
  end

  def request_email_change
    result = UserEmailChanges::RequestService.new(
      user: current_user,
      email: email_change_params.fetch(:email)
    ).call
    record_audit_event!(
      action: "user.email_change.request",
      target: current_user,
      metadata: { email_domain: email_domain(result.email_change.new_email) }
    )

    render json: {
      message: "新しいメールアドレスに確認メールを送信しました",
      pending_email: result.email_change.new_email
    }, status: :ok
  rescue ActionController::ParameterMissing => error
    render_api_error(:bad_request, "#{error.param} は必須です", status: :bad_request)
  rescue ActiveRecord::RecordInvalid => error
    record_email_change_failure!(error.record.errors.full_messages.first)
    render_validation_failed(error.record)
  rescue ActiveRecord::RecordNotUnique
    record_email_change_failure!("このメールアドレスは既に使用されています")
    render_validation_failed([ "このメールアドレスは既に使用されています" ])
  rescue StandardError => error
    record_email_change_failure!("確認メールの送信に失敗しました")
    Rails.logger.error("[me.email_change] delivery failed user_id=#{current_user.id} error=#{error.class}: #{error.message}")
    render_api_error(:email_delivery_failed, "確認メールの送信に失敗しました", status: :unprocessable_content)
  end

  def verify_email_change
    result = UserEmailChanges::ConfirmService.new(token: params[:token]).call
    record_audit_event!(
      action: "user.email_change.confirm",
      actor_user: result.user,
      organization: result.user.organization,
      target: result.user,
      metadata: { email_domain: email_domain(result.user.email) }
    )

    render json: {
      message: "メールアドレスを変更しました",
      email: result.user.email
    }, status: :ok
  rescue UserEmailChanges::ConfirmService::Failure => error
    record_email_change_failure!(error.message)
    render_api_error(:email_change_failed, error.message, status: error.status)
  rescue StandardError => error
    record_email_change_failure!("変更完了通知メールの送信に失敗しました")
    Rails.logger.error("[me.email_change] confirmation failed error=#{error.class}: #{error.message}")
    render_api_error(:email_delivery_failed, "変更完了通知メールの送信に失敗しました", status: :unprocessable_content)
  end

  def cancel_email_change
    email_change = current_user.pending_email_change

    if email_change.present?
      email_change.update!(cancelled_at: Time.current)
      record_audit_event!(
        action: "user.email_change.cancel",
        target: current_user,
        metadata: { email_domain: email_domain(email_change.new_email) }
      )
    end

    render json: { message: "メールアドレス変更申請を取り消しました" }, status: :ok
  end

  private

  def update_params
    params.permit(:display_name)
  end

  def email_change_params
    params.permit(:email)
  end

  def user_json(user)
    pending_email_change = user.pending_email_change

    {
      id: user.id,
      organization_id: user.organization_id,
      organization_name: user.organization.name,
      email: user.email,
      pending_email: pending_email_change&.new_email,
      name: user.name,
      display_name: user.display_name,
      role: user.role,
      suspended: user.suspended?,
      suspended_at: user.suspended_at,
      last_sign_in_at: user.last_sign_in_at,
      created_at: user.created_at,
      updated_at: user.updated_at
    }
  end

  def rate_limit_email_change_request!
    checks = [
      rate_limit_result("email-change-ip", request.remote_ip, EMAIL_CHANGE_REQUEST_IP_LIMIT, EMAIL_CHANGE_REQUEST_PERIOD)
    ]
    normalized_email = normalize_email(params[:email])
    checks << rate_limit_result("email-change-email", normalized_email, EMAIL_CHANGE_REQUEST_EMAIL_LIMIT, EMAIL_CHANGE_REQUEST_PERIOD) if normalized_email.present?

    limited_result = checks.find { |result| !result.allowed? }
    return if limited_result.nil?

    response.headers["Retry-After"] = limited_result.retry_after.to_s
    render_api_error(
      :rate_limited,
      "リクエスト数が上限を超えました。しばらく待ってから再試行してください",
      status: :too_many_requests
    )
  end

  def rate_limit_result(namespace, key, limit, period)
    Security::RateLimiter.new(
      namespace: namespace,
      key: key,
      limit: limit,
      period: period
    ).call
  end

  def normalize_email(email)
    email.to_s.strip.downcase
  end

  def email_domain(email)
    email.to_s.split("@", 2).last
  end

  def record_email_change_failure!(reason)
    actor = current_user_or_nil

    record_audit_event!(
      action: "user.email_change.failure",
      actor_user: actor,
      organization: actor&.organization,
      target: actor,
      outcome: "failure",
      metadata: { reason: reason }
    )
  end
end
