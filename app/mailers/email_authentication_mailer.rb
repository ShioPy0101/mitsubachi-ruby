class EmailAuthenticationMailer < ApplicationMailer
  def send_magic_link

    # メール本文に埋め込むログイン用のURLを生成する
    @login_url = "http://localhost:5173/auth/verify?token=#{params[:token]}"

    mail(
      to: params[:email],
      subject: "ログインリンク"
    )
  end
end