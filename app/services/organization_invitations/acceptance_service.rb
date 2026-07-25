module OrganizationInvitations
  class AcceptanceService
    Failure = Class.new(StandardError) do
      attr_reader :code, :message, :status

      def initialize(code, message, status)
        @code = code
        @message = message
        @status = status
        super(message)
      end
    end

    Result = Data.define(:invite, :membership)

    def self.call(token:, user:, now: Time.current)
      new(token:, user:, now:).call
    end

    def initialize(token:, user:, now:)
      @token = token.to_s
      @user = user
      @now = now
    end

    def call
      raise_failure(:invalid_invitation, "招待が見つかりません", :not_found) if token.blank?
      raise_failure(:user_suspended, "このユーザーは停止されています", :unauthorized) if user.suspended?

      invite = nil
      membership = nil

      ActiveRecord::Base.transaction do
        invite = OrganizationInvite.lock.includes(:organization).find_by(code: token)
        validate_invite!(invite)

        membership = OrganizationMembership.create!(
          user: user,
          organization: invite.organization,
          role: invite.role,
          status: :active,
          joined_at: now
        )
        invite.update!(used_at: now, used_by_user: user, stand_by_at: nil, stand_by_user: nil)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        raise_failure(:already_member, "既にこの組織に所属しています", :conflict)
      end

      Result.new(invite, membership)
    end

    private

    attr_reader :token, :user, :now

    def validate_invite!(invite)
      raise_failure(:invalid_invitation, "招待が見つかりません", :not_found) if invite.nil?
      raise_failure(:invitation_revoked, "招待は取り消されています", :gone) if invite.revoked?
      raise_failure(:invitation_already_accepted, "招待は既に承諾されています", :conflict) if invite.accepted?
      raise_failure(:invitation_expired, "招待リンクの有効期限が切れています", :unauthorized) if invite.expires_at <= now
      raise_failure(:organization_unavailable, "組織を利用できません", :gone) if invite.organization.nil?
      validate_email!(invite)
      raise_failure(:already_member, "既にこの組織に所属しています", :conflict) if user.organization_memberships.active.exists?(organization: invite.organization)
    end

    def validate_email!(invite)
      return if invite.email.blank?
      return if invite.email == user.email.downcase

      raise_failure(:email_mismatch, "招待先メールアドレスとログイン中のアカウントが一致しません", :forbidden)
    end

    def raise_failure(code, message, status)
      raise Failure.new(code, message, status)
    end
  end
end
