class UserEmailChangeMailer < ApplicationMailer
  def confirmation
    @user = params.fetch(:user)
    @email_change = params.fetch(:email_change)
    @confirmation_url = confirmation_url(params.fetch(:token))
    @expires_at = format_mail_time(@email_change.expires_at)

    mail(
      to: @email_change.new_email,
      subject: "【Mitsubachi】メールアドレス変更確認"
    )
  end

  def changed_notification
    @user = params.fetch(:user)
    @old_email = params.fetch(:old_email)
    @changed_at = format_mail_time(Time.current)

    mail(
      to: @old_email,
      subject: "【Mitsubachi】メールアドレス変更完了のお知らせ"
    )
  end

  private

  def confirmation_url(token)
    query = Rack::Utils.build_query(token: token)

    "#{ENV.fetch("FRONTEND_URL")}/settings/email-change/verify?#{query}"
  end

  def format_mail_time(time)
    I18n.l(time.in_time_zone, format: :mitsubachi_mail, locale: :ja)
  end
end
