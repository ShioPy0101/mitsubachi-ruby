class EmailAuthenticationsController < ApplicationController
  def create
    # POST /auth/email
    # JSONで受けた email を使って
    # 6桁コードを作り、DB保存し、メール送信する
    email = params[:email]

    # 1. email がない
    unless email.present?
      render json: {
        error: "email は必須です"
      }, status: :bad_request
      return
    end

    # 2. email の形式がざっくりおかしい
    unless email.include?("@")
      render json: {
        error: "email の形式が正しくありません"
      }, status: :unprocessable_entity
      return
    end

    code = rand(100_000..999_999).to_s

    # 3. DB保存
    EmailAuthentication.create!(
      email: email,
      code: code
    )

    # 4. メール送信
    EmailAuthenticationMailer
      .with(email: email, code: code)
      .send_code
      .deliver_later

    render json: {
      message: "認証コードを送信しました"
    }, status: :ok
  end
end

  def verify
    # POST /auth/verify
    # JSONで受けた email と code を照合する
    # 成功したらログイン状態を作る
  end
end