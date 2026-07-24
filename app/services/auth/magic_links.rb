module Auth
  class MagicLinks
    REGISTRATION_STAND_BY_WINDOW = 15.minutes
    AUTHENTICATION_TOKEN_TTL = 15.minutes

    Failure = Class.new(StandardError) do
      attr_reader :message, :status

      def initialize(message, status)
        @message = message
        @status = status
        super(message)
      end
    end

    VerificationResult = Data.define(:user, :organization_invite, :purpose)
    RequestResult = Data.define(:email, :token, :user, :organization, :organization_invite, :authentication)

    def self.normalize_email(email)
      email.to_s.strip.downcase
    end

    def self.normalize_display_name(display_name)
      display_name.to_s.strip.presence
    end

    def request_registration(email:, invite_code:, display_name: nil)
      email = self.class.normalize_email(email)
      display_name = self.class.normalize_display_name(display_name)

      raise Failure.new("email は必須です", :bad_request) if email.blank?
      raise Failure.new("invite_code は必須です", :bad_request) if invite_code.blank?
      raise Failure.new("表示名は100文字以内で入力してください", :bad_request) if display_name&.length.to_i > 100

      build_registration_request!(email:, invite_code:, display_name:)
    end

    def request_login(email:)
      email = self.class.normalize_email(email)
      raise Failure.new("email は必須です", :bad_request) if email.blank?

      build_login_request!(email:)
    end

    def verify(raw_token, expected_purpose: nil)
      raise Failure.new("token は必須です", :bad_request) if raw_token.blank?

      verify_token!(raw_token, expected_purpose:)
    end

    private

    def build_registration_request!(email:, invite_code:, display_name:)
      raw_token = SecureRandom.urlsafe_base64(32)
      hashed_token = Digest::SHA256.hexdigest(raw_token)
      now = Time.current
      stand_by_user = nil
      invite = nil
      authentication = nil

      ActiveRecord::Base.transaction do
        invite = OrganizationInvite.lock.find_by(code: invite_code)
        validate_invite_for_registration!(invite, now)
        existing_user = find_user_by_email(email)
        existing_user&.lock!
        validate_user_for_registration!(existing_user, invite)
        validate_display_name_for_registration!(display_name, invite, existing_user)
        clear_stale_stand_by!(existing_user, now) if existing_user.present?

        stand_by_user = existing_user || User.new(email: email)
        stand_by_user.organization = invite.organization
        stand_by_user.display_name = display_name if display_name.present?
        stand_by_user.password = SecureRandom.base64(32) unless stand_by_user.persisted?
        stand_by_user.save!
        expire_active_registration_authentications!(invite, now)
        invite.update!(stand_by_at: now, stand_by_user: stand_by_user)

        authentication = EmailAuthentication.create!(
          email: email,
          token: hashed_token,
          expires_at: now + AUTHENTICATION_TOKEN_TTL,
          purpose: "registration",
          delivery_token: raw_token,
          organization_invite: invite
        )
      end

      RequestResult.new(email, raw_token, stand_by_user, invite.organization, invite, authentication)
    end

    def build_login_request!(email:)
      raw_token = SecureRandom.urlsafe_base64(32)
      hashed_token = Digest::SHA256.hexdigest(raw_token)
      now = Time.current
      user = nil
      authentication = nil

      ActiveRecord::Base.transaction do
        user = find_user_by_email(email)
        validate_user_for_login!(user)
        user.lock!
        user.reload
        validate_user_for_login!(user)
        expire_active_login_authentications!(email, now)

        authentication = EmailAuthentication.create!(
          email: email,
          token: hashed_token,
          expires_at: now + AUTHENTICATION_TOKEN_TTL,
          purpose: "login",
          delivery_token: raw_token
        )
      end

      RequestResult.new(email, raw_token, user, user.organization, nil, authentication)
    end

    def verify_token!(raw_token, expected_purpose:)
      hashed_token = Digest::SHA256.hexdigest(raw_token)
      now = Time.current
      verified_user = nil
      failure = nil
      authentication = nil

      ActiveRecord::Base.transaction do
        authentication = EmailAuthentication.lock.find_by(token: hashed_token)
        validate_authentication!(authentication, now)
        validate_authentication_purpose!(authentication, expected_purpose) if expected_purpose.present?

        user = find_user_by_email(authentication.email)
        validate_user_presence!(user)
        user.lock!
        user.reload

        if user.suspended?
          mark_authentication_used!(authentication, now)
          failure = Failure.new("このユーザーは停止されています", :unauthorized)
          next
        end

        invite = authentication.organization_invite
        if authentication.login?
          raise Failure.new("ログイン用リンクが正しくありません", :unauthorized) if invite.present?

          reject_provisional_login_user!(user)
          mark_authentication_used!(authentication, now)
          verified_user = user
          next
        end

        raise Failure.new("登録用リンクが正しくありません", :unauthorized) if invite.nil?

        invite.lock!
        invite.reload
        validate_invite_for_verification!(invite, user, now)
        invite.update!(used_at: now, used_by_user: user, stand_by_at: nil, stand_by_user: nil)
        mark_authentication_used!(authentication, now)
        verified_user = user
      end

      raise failure if failure

      VerificationResult.new(verified_user, authentication.organization_invite, authentication.purpose)
    end

    def validate_invite_for_registration!(invite, now)
      raise Failure.new("invite_code が正しくありません", :unauthorized) if invite.nil?
      raise Failure.new("invite_code の有効期限が切れています", :unauthorized) if invite.expires_at <= now
      raise Failure.new("この invite_code は既に使用されています", :unauthorized) if invite.used_at.present?
      raise Failure.new("この invite_code は現在検証中です", :conflict) if invite_stand_by_active?(invite, now)
    end

    def validate_user_for_registration!(user, invite)
      return if user.nil?
      raise Failure.new("このユーザーは停止されています", :unauthorized) if user.suspended?
      raise Failure.new("このメールアドレスはすでに登録されています", :conflict) unless provisional_user?(user)
      raise Failure.new("このメールアドレスは現在検証中です", :conflict) if active_stand_by_invite_for(user).present?
      raise Failure.new("このメールアドレスはすでに登録されています", :conflict) if user.organization_id != invite.organization_id && !stale_provisional_user?(user)
    end

    def validate_user_for_login!(user)
      validate_user_presence!(user)
      raise Failure.new("このユーザーは停止されています", :unauthorized) if user.suspended?
      reject_provisional_login_user!(user)
    end

    def validate_display_name_for_registration!(display_name, invite, existing_user)
      return if display_name.blank?

      scope = invite.organization.users.where(display_name: display_name)
      scope = scope.where.not(id: existing_user.id) if existing_user.present?
      return unless scope.exists?

      raise Failure.new("この表示名は既に使用されています", :conflict)
    end

    def validate_user_presence!(user)
      raise Failure.new("ユーザーが存在しません", :unauthorized) if user.nil?
    end

    def reject_provisional_login_user!(user)
      raise Failure.new("登録用リンクでメール認証を完了してください", :unauthorized) if provisional_user?(user)
    end

    def validate_authentication!(authentication, now)
      raise Failure.new("リンクが正しくありません", :unauthorized) if authentication.nil?
      authentication.reload
      raise Failure.new("このリンクは既に使用されています", :unauthorized) if authentication.used_at.present?
      raise Failure.new("リンクの有効期限が切れています", :unauthorized) if authentication.expires_at <= now
    end

    def validate_authentication_purpose!(authentication, expected_purpose)
      return if authentication.purpose == expected_purpose

      raise Failure.new("リンクの用途が正しくありません", :unauthorized)
    end

    def validate_invite_for_verification!(invite, user, now)
      raise Failure.new("この invite_code は既に使用されています", :unauthorized) if invite.used_at.present?
      raise Failure.new("この invite_code の有効期限が切れています", :unauthorized) if invite.expires_at <= now
      raise Failure.new("このユーザーは stand-by ではありません", :unauthorized) if invite.stand_by_user_id != user.id
      raise Failure.new("この invite_code は現在検証中ではありません", :unauthorized) unless invite_stand_by_active?(invite, now)
    end

    def mark_authentication_used!(authentication, now)
      authentication.update!(used_at: now)
    end

    def expire_active_login_authentications!(email, now)
      EmailAuthentication.where(purpose: "login", used_at: nil)
                         .where("expires_at > ?", now)
                         .where("LOWER(email) = ?", email.downcase)
                         .update_all(used_at: now, updated_at: now)
    end

    def expire_active_registration_authentications!(invite, now)
      invite.email_authentications
            .where(purpose: "registration", used_at: nil)
            .where("expires_at > ?", now)
            .update_all(used_at: now, updated_at: now)
    end

    def find_user_by_email(email)
      User.find_by("LOWER(email) = ?", self.class.normalize_email(email))
    end

    def invite_stand_by_active?(invite, now = Time.current)
      invite.stand_by_user.present? &&
        invite.stand_by_at.present? &&
        invite.stand_by_at > REGISTRATION_STAND_BY_WINDOW.ago(now)
    end

    def provisional_user?(user)
      OrganizationInvite.where(stand_by_user: user, used_at: nil).exists? &&
        !OrganizationInvite.where(used_by_user: user).exists?
    end

    def stale_provisional_user?(user)
      OrganizationInvite.where(stand_by_user: user, used_at: nil)
                        .where("stand_by_at IS NULL OR stand_by_at <= ?", REGISTRATION_STAND_BY_WINDOW.ago)
                        .exists?
    end

    def active_stand_by_invite_for(user)
      OrganizationInvite.where(stand_by_user: user, used_at: nil)
                        .where("stand_by_at > ?", REGISTRATION_STAND_BY_WINDOW.ago)
                        .first
    end

    def clear_stale_stand_by!(user, now = Time.current)
      OrganizationInvite.where(stand_by_user: user, used_at: nil)
                        .where("stand_by_at IS NULL OR stand_by_at <= ?", REGISTRATION_STAND_BY_WINDOW.ago(now))
                        .update_all(stand_by_user_id: nil, stand_by_at: nil, updated_at: now)
    end
  end
end
