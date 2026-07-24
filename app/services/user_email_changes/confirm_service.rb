module UserEmailChanges
  class ConfirmService
    Failure = Class.new(StandardError) do
      attr_reader :message, :status

      def initialize(message, status)
        @message = message
        @status = status
        super(message)
      end
    end

    Result = Data.define(:user, :old_email, :email_change)

    def initialize(token:)
      @token = token
    end

    def call
      raise Failure.new("token は必須です", :unprocessable_content) if @token.blank?

      result = nil
      now = Time.current

      ActiveRecord::Base.transaction do
        email_change = UserEmailChange.lock.find_by(token_digest: UserEmailChange.digest_token(@token))
        validate_email_change!(email_change, now)

        user = email_change.user
        user.lock!
        user.reload
        validate_user!(user)
        validate_email_available!(email_change, user)

        email_change.update!(used_at: now)
        old_email = user.email
        user.update!(email: email_change.new_email)
        UserEmailChangeMailer.with(user: user, old_email: old_email).changed_notification.deliver_now
        result = Result.new(user, old_email, email_change)
      end

      result
    rescue ActiveRecord::RecordNotUnique
      raise Failure.new("このメールアドレスは既に使用されています", :unprocessable_content)
    end

    private

    def validate_email_change!(email_change, now)
      raise Failure.new("token が正しくありません", :unprocessable_content) if email_change.nil?
      raise Failure.new("この確認リンクは既に使用されています", :gone) if email_change.used?
      raise Failure.new("メールアドレス変更申請は取り消されています", :gone) if email_change.cancelled?
      raise Failure.new("確認リンクの有効期限が切れています", :gone) if email_change.expired?(now)
    end

    def validate_user!(user)
      raise Failure.new("このユーザーは停止されています", :forbidden) if user.suspended?
    end

    def validate_email_available!(email_change, user)
      scope = User.where("LOWER(email) = ?", email_change.new_email.downcase).where.not(id: user.id)
      return unless scope.exists?

      raise Failure.new("このメールアドレスは既に使用されています", :unprocessable_content)
    end
  end
end
