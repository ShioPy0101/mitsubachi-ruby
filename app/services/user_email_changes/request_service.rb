module UserEmailChanges
  class RequestService
    Result = Data.define(:email_change, :token)

    def initialize(user:, email:)
      @user = user
      @email = email
    end

    def call
      raw_token, token_digest = UserEmailChange.generate_token_pair
      email_change = nil

      ActiveRecord::Base.transaction do
        @user.lock!
        @user.user_email_changes.active.update_all(cancelled_at: Time.current, updated_at: Time.current)

        email_change = @user.user_email_changes.create!(
          new_email: @email,
          token_digest: token_digest,
          expires_at: UserEmailChange::TOKEN_TTL.from_now
        )

        UserEmailChangeMailer.with(
          user: @user,
          email_change: email_change,
          token: raw_token
        ).confirmation.deliver_now
      end

      Result.new(email_change, raw_token)
    end
  end
end
