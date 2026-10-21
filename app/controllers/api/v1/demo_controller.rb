# デモ専用プロセスからのみ公開する。Devise・User・DriveItem を利用せず、
# 合成データ以外へのアクセス経路を持たないため通常 API の Controller は継承しない。
class Api::V1::DemoController < ActionController::API
  before_action :require_demo_runtime!
  before_action :authenticate_demo!, only: %i[items transfer]

  def login
    return render_error("invalid_email", "デモ用メールアドレスを入力してください", :unprocessable_content) unless params[:email].to_s.strip.downcase == Demo::Access::EMAIL

    render json: { email: Demo::Access.issue }
  end

  def verify
    render json: { token: Demo::Access.verify(params[:token]) }
  rescue Demo::Access::InvalidLink
    render_error("invalid_demo_link", "デモ用リンクが無効、使用済み、または有効期限切れです", :unauthorized)
  end

  def items
    render json: { items: Demo::Catalog::ITEMS }
  end

  def transfer
    render_error("demo_operation_restricted", "デモテナントのため、この操作はできません", :forbidden)
  end

  private

  def require_demo_runtime!
    response.headers["Cache-Control"] = "no-store"
    return head :not_found unless FeatureFlags.demo_mode? && FeatureFlags.enabled?(:demo_tenant) && request.host == Demo::Access::API_HOST
    return if request.get? || request.headers["Origin"] == Demo::Access::FRONTEND_ORIGIN

    # Cookie を使わない公開デモでも、第三者サイトからのリンク大量発行を拒否する。
    head :forbidden
  end

  def authenticate_demo!
    scheme, token = request.authorization.to_s.split(" ", 2)
    return if scheme == "Bearer" && Demo::Access.authenticated?(token)

    render_error("unauthorized", "デモ用の認証メールからログインしてください", :unauthorized)
  end

  def render_error(code, message, status)
    render json: { error: { code: code, message: message } }, status: status
  end
end
