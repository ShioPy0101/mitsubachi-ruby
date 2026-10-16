module UserEmailChanges
  # 二段階の所有確認を担う。旧メール承認tokenは新メール確認tokenへ置換し、用途を跨ぐ再利用を防ぐ。
  class ConfirmService
    Failure = Class.new(StandardError) do
      attr_reader :status, :code

      def initialize(message, status, code: :email_change_failed)
        @status = status
        @code = code
        super(message)
      end
    end

    Result = Data.define(:user, :old_email, :email_change)

    def initialize(token:)
      @token = token
    end

    def approve
      process!(approval: true)
    end

    def call
      process!(approval: false)
    end

    private

    def process!(approval:)
      EmailIdentityKey.verify!
      raise Failure.new("token は必須です", :unprocessable_content) if @token.blank?

      digest = UserEmailChange.digest_token(@token)
      email_change = UserEmailChange.find_by(token_digest: digest)
      raise Failure.new("token が正しくありません", :unprocessable_content) if email_change.nil?

      result = nil
      ActiveRecord::Base.transaction do
        # 申請・取消と同じUser→申請の順にlockし、同時操作でも順序とidentityを再確認する。
        user = email_change.user
        user.lock!
        email_change.lock!
        validate_email_change!(email_change, user, digest, approval:)
        addresses = email_change.delivery_addresses
        unless EmailIdentities::Digest.call(addresses.fetch("old")) == user.email_digest &&
            EmailIdentities::Digest.call(addresses.fetch("new")) == email_change.new_email_digest
          raise Failure.new("メール変更情報が一致しません", :unprocessable_content)
        end

        if approval
          raw_token, token_digest = UserEmailChange.generate_token_pair
          email_change.update!(old_email_approved_at: Time.current, token_digest: token_digest)
          UserEmailChangeMailer.with(user: user, email_change: email_change, new_email: addresses.fetch("new"), token: raw_token).confirmation.deliver_now
        else
          email_change.update!(used_at: Time.current, delivery_addresses_ciphertext: nil)
          user.update!(email_digest: email_change.new_email_digest, reset_password_token: nil, remember_created_at: nil)
          # SMTP失敗時はDB更新をrollbackする。外部配信そのものはDB transactionで取消できない。
          UserEmailChangeMailer.with(user: user, old_email: addresses.fetch("old")).changed_notification.deliver_now
        end
        result = Result.new(user, nil, email_change)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      raise Failure.new("このメールアドレスは既に使用されています", :unprocessable_content)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      raise Failure.new("メール変更申請の有効期限が切れています。再度申請してください", :gone)
    end

    def validate_email_change!(change, user, digest, approval:)
      raise Failure.new("token が正しくありません", :unprocessable_content) if change.token_digest != digest
      raise Failure.new("この確認リンクは既に使用されています", :gone) if change.used?
      raise Failure.new("メールアドレス変更申請は取り消されています", :gone) if change.cancelled?
      raise Failure.new("確認リンクの有効期限が切れています", :gone) if change.expired?
      raise Failure.new("このユーザーは停止されています", :forbidden) if user.suspended?
      raise Failure.new("メール変更申請後にアカウント情報が変更されています", :gone) if user.email_digest != change.old_email_digest
      if approval == change.old_email_approved_at.present?
        raise Failure.new("リンクの用途が正しくありません", :unprocessable_content)
      end
      if User.where(email_digest: change.new_email_digest).where.not(id: user.id).exists?
        raise Failure.new("このメールアドレスは既に使用されています", :unprocessable_content)
      end
    end
  end
end
