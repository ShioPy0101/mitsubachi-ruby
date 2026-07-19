class EmailAuthenticationMailer < ApplicationMailer
  def registration_link
    assign_authentication_mail_values

    mail(
      to: params[:email],
      subject: "【Mitsubachi】アカウント登録のご案内"
    )
  end

  def login_link
    assign_authentication_mail_values

    mail(
      to: params[:email],
      subject: "【Mitsubachi】ログインリンクのご案内"
    )
  end

  private

  def assign_authentication_mail_values
    @organization = params.fetch(:organization)
    @authentication = params.fetch(:authentication)
    @auth_url = authentication_url(authentication_token, @authentication.purpose)
    @issued_at = format_mail_time(@authentication.created_at)
    @expires_at = format_mail_time(@authentication.expires_at)
  end

  def authentication_token
    params[:token].presence || params.fetch(:authentication).delivery_token.presence ||
      raise(ArgumentError, "Email authentication delivery token is unavailable")
  end

  def authentication_url(token, purpose)
    query = Rack::Utils.build_query(token: token, purpose: purpose)

    "#{ENV.fetch("FRONTEND_URL")}/auth/verify?#{query}"
  end

  def format_mail_time(time)
    I18n.l(time.in_time_zone, format: :mitsubachi_mail, locale: :ja)
  end
end
