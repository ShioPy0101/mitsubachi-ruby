class ApplicationController < ActionController::API
  include ActionController::Cookies
  include ActionController::RequestForgeryProtection

  protect_from_forgery with: :exception, unless: -> { !Rails.configuration.action_controller.allow_forgery_protection }
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActionController::InvalidAuthenticityToken, with: :render_invalid_authenticity_token
  before_action :reject_suspended_user!

  private

  def authenticate_user!(_options = {})
    return if user_signed_in?

    render_api_error(:unauthorized, "ログインが必要です。", status: :unauthorized)
  end

  def record_operation!(operation_type:, actor_user: current_user_or_nil, organization: current_organization_for_operation(actor_user), target: nil, result: "success", changes: {}, metadata: {})
    OperationLogs::Recorder.record!(
      operation_type: operation_type,
      actor_user: actor_user,
      organization: organization,
      target: target,
      result: result,
      changes: changes,
      metadata: { client_type: "web" }.merge(metadata),
      request: request
    )
  end

  def current_organization
    @current_organization || current_user&.organization
  end

  def current_membership
    return @current_membership if defined?(@current_membership)
    return nil unless current_user && current_organization

    @current_membership = current_user.active_membership_for(current_organization)
  end

  def set_current_organization
    if current_user.system_admin?
      # system_admin は任意の organization を管理できるが、後続の監査ログや scope は
      # URL で選択された organization を current_organization として扱う。
      @current_organization = Organization.find(request.path_parameters[:organization_id])
      @current_membership = current_user.active_membership_for(@current_organization)
      return
    end

    # 一般ユーザーは active membership 経由で organization を解決する。
    # Organization.find 後に membership を比較すると、未所属 organization の存在有無を
    # レスポンス差から推測できるため、membership relation を入口にする。
    @current_membership =
      current_user
        .organization_memberships
        .active
        .includes(:organization)
        .find_by!(organization_id: request.path_parameters[:organization_id])

    @current_organization = @current_membership.organization
  end

  def organization_path_scope?
    request.path_parameters[:organization_id].present?
  end

  def require_organization_admin!
    return if current_user&.system_admin?
    raise ActiveRecord::RecordNotFound unless current_membership&.organization_admin?
  end

  def create_authenticated_session!(user)
    reset_session
    sign_in(user)
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

  def current_organization_for_operation(actor_user)
    return current_organization if current_organization.present?

    actor_user&.organization
  end

  def reject_suspended_user!
    return unless current_user&.suspended?
    # 停止ユーザーは通常 API から即時排除する一方、ログアウトと CSRF token 再取得は
    # セッション復旧に必要なため許可する。
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
