# app/mailers/email_authentication_mailer.rb
class EmailAuthenticationMailer < ApplicationMailer
  def send_magic_link
    @login_url =
      "#{ENV.fetch("FRONTEND_URL")}/auth/verify?token=#{params[:token]}"

    mail(
      to: params[:email],
      subject: "ログインリンク"
    )
  end
end
