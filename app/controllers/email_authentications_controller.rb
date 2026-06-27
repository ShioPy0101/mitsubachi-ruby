class EmailAuthenticationsController < ApplicationController
  def create
    email = params[:email]

    unless email.present?
      render json: { error: "email は必須です" }, status: :bad_request
      return
    end

    token = SecureRandom.urlsafe_base64(32)

    EmailAuthentication.create!(
      email: email,
      token: token,
      expires_at: 15.minutes.from_now
    )

    EmailAuthenticationMailer
      .with(email: email, token: token)
      .send_magic_link
      .deliver_later

    render json: {
      message: "認証リンクを送信しました"
    }, status: :ok
  end
end

  def verify
    # POST /auth/verify
    # JSONで受けた email と code を照合する
    # 成功したらログイン状態を作る
  end
end