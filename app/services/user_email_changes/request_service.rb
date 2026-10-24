module UserEmailChanges
  class RequestService
    REAUTHENTICATION_TTL = 5.minutes
    Result = Data.define(:email_change, :token)

    def initialize(user:, email:, reauthentication_id: nil)
      @user = user
      @email = EmailIdentities::Digest.normalize(email)
      @reauthentication_id = reauthentication_id
    end

    def call
      EmailIdentityKey.verify!
      raw_token, token_digest = UserEmailChange.generate_token_pair
      email_change = nil

      ActiveRecord::Base.transaction do
        @user.lock!
        authentication = EmailAuthentication.lock.find_by(id: @reauthentication_id)
        validate_reauthentication!(authentication)
        old_email = EmailIdentities::DeliveryPayload.decrypt(authentication.recipient_ciphertext, purpose: "email_change_reauthentication")
        unless EmailIdentities::Digest.call(old_email) == @user.email_digest
          raise_reauthentication_required!
        end

        @user.user_email_changes.active.update_all(cancelled_at: Time.current, delivery_addresses_ciphertext: nil, updated_at: Time.current)
        expires_at = UserEmailChange::TOKEN_TTL.from_now
        email_change = @user.user_email_changes.create!(
          new_email: @email,
          old_email_digest: @user.email_digest,
          delivery_addresses_ciphertext: EmailIdentities::DeliveryPayload.encrypt({ old: old_email, new: @email }, purpose: "email_change", expires_at: expires_at),
          token_digest: token_digest,
          expires_at: expires_at
        )

        UserEmailChangeMailer.with(user: @user, email_change: email_change, old_email: old_email, token: raw_token).approval.deliver_now
        authentication.update!(reauthentication_consumed_at: Time.current, recipient_ciphertext: nil)
      end

      Result.new(email_change, raw_token)
    end

    private

    def validate_reauthentication!(authentication)
      valid = authentication && authentication.email_change_reauthentication? &&
        authentication.used_at.present? && authentication.used_at > REAUTHENTICATION_TTL.ago &&
        authentication.expires_at > Time.current && authentication.reauthentication_consumed_at.nil? &&
        authentication.email_digest == @user.email_digest && !@user.suspended?
      raise_reauthentication_required! unless valid
    end

    def raise_reauthentication_required!
      raise ConfirmService::Failure.new("メールアドレス変更のため再ログインしてください", :unauthorized, code: :reauthentication_required)
    end
  end
end
