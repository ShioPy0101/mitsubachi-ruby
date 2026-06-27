class EmailAuthenticationsController < ApplicationController
  def create
    email = params[:email]

    # email が空の場合はエラーを返す
    unless email.present?
      render json: { error: "email は必須です" }, status: :bad_request
      return
    end

    # token を生成して、EmailAuthentication モデルに保存する
    token = SecureRandom.urlsafe_base64(32)

    hash_token = Digest::SHA256.hexdigest(token)

    # EmailAuthentication モデルに保存する
    EmailAuthentication.create!(
      email: email,
      token: hash_token,
      expires_at: 15.minutes.from_now
    )

    # メールを送信する
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
    token = params[:token]

    hash_token = Digest::SHA256.hexdigest(token)

    authentication = EmailAuthentication.find_by(token: hash_token)

    if authentication.nil?
      render json: { error: "リンクが正しくありません" }, status: :unauthorized
      return
    end

    if authentication.expires_at < Time.current
      render json: { error: "リンクの有効期限が切れています" }, status: :unauthorized
      return
    end

    if authentication.used_at.present?
      render json: { error: "このリンクは既に使用されています" }, status: :unauthorized
      return
    end

    user = User.find_or_create_by!(email: authentication.email)

    authentication.update!(used_at: Time.current)

    # ここで最終的にログイン状態を作る
    # sign_in(user)

    render json: {
      message: "ログインに成功しました",
      user: {
        id: user.id,
        email: user.email
      }
    }, status: :ok
  end
end