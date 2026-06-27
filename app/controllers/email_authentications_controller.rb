class EmailAuthenticationsController < ApplicationController

  # ユーザー作成
  def create
    email = params[:email]
    invite_code = params[:invite_code]

    # email が空の場合はエラーを返す
    unless email.present?
      render json: { error: "email は必須です" }, status: :bad_request
      return
    end

    # invite_code が空の場合はエラーを返す
    unless invite_code.present?
      render json: { error: "invite_code は必須です" }, status: :bad_request
      return
    end

    # すでにユーザーが存在する場合はエラーを返す
    if User.exists?(email: email)
      render json: { error: "このメールアドレスはすでに登録されています" }, status: :conflict
      return
    end

    # Invitation code を使って OrganizationInvite を検索する
    invite = OrganizationInvite.find_by(code: invite_code)

    # invite_code が有効かどうかをチェックする
    if invite.nil?
      render json: { error: "invite_code が正しくありません" }, status: :unauthorized
      return
    end

    # invite_code が有効期限内かどうかをチェックする
    if invite.expires_at < Time.current
      render json: { error: "invite_code の有効期限が切れています" }, status: :unauthorized
      return
    end

    # invite_code が既に使用されているかどうかをチェックする
    if invite.used_at.present?
      render json: { error: "この invite_code は既に使用されています" }, status: :unauthorized
      return
    end

    # 認証用 token を生成して、EmailAuthentication モデルに保存する
    email_auth_token = SecureRandom.urlsafe_base64(32)

    hash_email_auth_token = Digest::SHA256.hexdigest(email_auth_token)

    # invite_code をstand-byにする
    # パスワードを設定していない仮ユーザーを作成する（メール専用のため）
    invite.update!(
        stand_by_at: Time.current, 
        stand_by_user: User.find_or_create_by!(
                                      email: email, 
                                      organization: invite.organization
                                    ) 
        do |new_user|
      new_user.password = SecureRandom.base64(32)
    end)

    # EmailAuthentication モデルに保存する
    EmailAuthentication.create!(
      email: email,
      token: hash_email_auth_token,
      expires_at: 15.minutes.from_now,
    )

    # メールを送信する
    EmailAuthenticationMailer
      .with(email: email, token: email_auth_token)
      .send_magic_link
      .deliver_later

    render json: {
      message: "認証リンクを送信しました"
    }, status: :ok
  end

  def login
    email = params[:email]

    # email が空の場合はエラーを返す
    unless email.present?
      render json: { error: "email は必須です" }, status: :bad_request
      return
    end
    # 認証用 token を生成して、EmailAuthentication モデルに保存する
    email_auth_token = SecureRandom.urlsafe_base64(32)

    hash_email_auth_token = Digest::SHA256.hexdigest(email_auth_token)

    # EmailAuthentication モデルに保存する
    EmailAuthentication.create!(
      email: email,
      token: hash_email_auth_token,
      expires_at: 15.minutes.from_now
    )

    # メールを送信する
    EmailAuthenticationMailer
      .with(email: email, token: email_auth_token)
      .send_magic_link
      .deliver_later

    render json: {
      message: "認証リンクを送信しました"
    }, status: :ok
  end

  def verify
    token = params[:token]

    # バリテーション
    unless token.present?
      render json: { error: "token は必須です" }, status: :bad_request
      return
    end

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

    # 認証が成功したとき、仮ユーザーを本登録ユーザーに変換する
    user = User.find_by(email: authentication.email)

    # user が存在しない場合はエラーを返す
    if user.nil?
      render json: { error: "ユーザーが存在しません" }, status: :unauthorized
      return
    end

    # OrganizationInvite の stand_by_user が user であることを確認する
    invite = OrganizationInvite.find_by(stand_by_user: user, organization: user.organization)

    # invite が存在しない場合はエラーを返す
    if invite.nil?
      render json: { error: "このユーザーは stand-by ではありません" }, status: :unauthorized
      return
    end

    if invite.stand_by_user != user
      render json: { error: "このユーザーは stand-by ではありません" }, status: :unauthorized
      return
    end

    if invite.used_at.present?
      render json: { error: "この invite_code は既に使用されています" }, status: :unauthorized
      return
    end

    if invite.expires_at < Time.current
      render json: { error: "この invite_code の有効期限が切れています" }, status: :unauthorized
      return
    end
    
    # 仮ユーザーを本登録ユーザーに変換する
    # 条件：stand_by_user が user であり、used_at が nil であり、expires_at が現在時刻より後であること
    if invite.stand_by_user == user && invite.used_at.nil? && invite.expires_at >= Time.current
      # invite_code を使用済みにする
      invite.update!(used_at: Time.current, used_by_user: user)
    end

    # 認証が成功した場合、ユーザーをログインさせる
    authentication.update!(used_at: Time.current)

    # ログイン状態を作る
    sign_in(user)

    render json: {
      message: "ログインに成功しました",
      user: {
        id: user.id,
        email: user.email
      }
    }, status: :ok
  end
end