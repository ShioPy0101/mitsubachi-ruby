class EmailAuthenticationsController < ApplicationController
  REGISTRATION_STAND_BY_WINDOW = 15.minutes

  # ユーザー作成
  def create
    email = normalize_email(params[:email])
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

    # invite_code が現在 stand-by 状態かどうかをチェックする
    if invite_stand_by_active?(invite)
      render json: { error: "この invite_code は現在検証中です" }, status: :conflict
      return
    end

    existing_user = find_user_by_email(email)

    if existing_user.present? && !provisional_user?(existing_user)
      render json: { error: "このメールアドレスはすでに登録されています" }, status: :conflict
      return
    end

    if existing_user.present? && active_stand_by_invite_for(existing_user).present?
      render json: { error: "このメールアドレスは現在検証中です" }, status: :conflict
      return
    end

    clear_stale_stand_by!(existing_user) if existing_user.present?

    # 認証用 token を生成して、EmailAuthentication モデルに保存する
    email_auth_token = SecureRandom.urlsafe_base64(32)

    hash_email_auth_token = Digest::SHA256.hexdigest(email_auth_token)

    # invite_code をstand-byにする
    # パスワードを設定していない仮ユーザーを作成する（メール専用のため）
    stand_by_user = existing_user || User.new(email: email)
    stand_by_user.organization = invite.organization

    unless stand_by_user.persisted?
      stand_by_user.password = SecureRandom.base64(32)
    end
    stand_by_user.save!

    invite.update!(
      stand_by_at: Time.current,
      stand_by_user: stand_by_user
    )

    # EmailAuthentication モデルに保存する
    EmailAuthentication.create!(
      email: email,
      token: hash_email_auth_token,
      expires_at: 15.minutes.from_now,
      organization_invite: invite
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
    email = normalize_email(params[:email])

    # email が空の場合はエラーを返す
    unless email.present?
      render json: { error: "email は必須です" }, status: :bad_request
      return
    end

    user = find_user_by_email(email)

    if user.nil?
      render json: { error: "ユーザーが存在しません" }, status: :unauthorized
      return
    end

    if provisional_user?(user)
      render json: { error: "登録用リンクでメール認証を完了してください" }, status: :unauthorized
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
    invite = authentication.organization_invite

    if invite.nil?
      ActiveRecord::Base.transaction do
        authentication.lock!
        authentication.reload

        if authentication.used_at.present?
          render json: { error: "このリンクは既に使用されています" }, status: :unauthorized
          raise ActiveRecord::Rollback
        end

        authentication.update!(used_at: Time.current)
      end

      return if performed?

      sign_in(user)
      render json: {
  message: "ログインに成功しました",
  user: {
    id: user.id,
    email: user.email
  }
}, status: :ok
      return
    end


    ActiveRecord::Base.transaction do
      authentication.lock!
      invite.lock!

      authentication.reload
      invite.reload

      if authentication.used_at.present?
        render json: { error: "このリンクは既に使用されています" }, status: :unauthorized
        raise ActiveRecord::Rollback
      end

      if authentication.expires_at < Time.current
        render json: { error: "リンクの有効期限が切れています" }, status: :unauthorized
        raise ActiveRecord::Rollback
      end

      if invite.stand_by_user != user
        render json: { error: "このユーザーは stand-by ではありません" }, status: :unauthorized
        raise ActiveRecord::Rollback
      end

      if invite.used_at.present?
        render json: { error: "この invite_code は既に使用されています" }, status: :unauthorized
        raise ActiveRecord::Rollback
      end

      if invite.expires_at < Time.current
        render json: { error: "この invite_code の有効期限が切れています" }, status: :unauthorized
        raise ActiveRecord::Rollback
      end

      invite.update!(
        used_at: Time.current,
        used_by_user: user,
        stand_by_at: nil,
        stand_by_user: nil
      )

      authentication.update!(used_at: Time.current)
    end

    return if performed?

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

  private

  def normalize_email(email)
    email.to_s.strip.downcase
  end

  def find_user_by_email(email)
    User.find_by("LOWER(email) = ?", email.downcase)
  end

  def invite_stand_by_active?(invite)
    invite.stand_by_user.present? &&
      invite.stand_by_at.present? &&
      invite.stand_by_at > REGISTRATION_STAND_BY_WINDOW.ago
  end

  def provisional_user?(user)
    OrganizationInvite.where(stand_by_user: user, used_at: nil).exists? &&
      !OrganizationInvite.where(used_by_user: user).exists?
  end

  def active_stand_by_invite_for(user)
    OrganizationInvite
      .where(stand_by_user: user, used_at: nil)
      .where("stand_by_at > ?", REGISTRATION_STAND_BY_WINDOW.ago)
      .first
  end

  def clear_stale_stand_by!(user)
    OrganizationInvite
      .where(stand_by_user: user, used_at: nil)
      .where("stand_by_at IS NULL OR stand_by_at <= ?", REGISTRATION_STAND_BY_WINDOW.ago)
      .update_all(stand_by_user_id: nil, stand_by_at: nil, updated_at: Time.current)
  end
end
