module Deployment
  class MigrationVerifier
    def call(now: Time.current)
      pending_user_ids = pending_registration_user_ids(now:)
      users_requiring_membership = User.where.not(role: User.roles[:system_admin]).where.not(id: pending_user_ids)
      users_without_membership = users_requiring_membership.where.not(
        id: OrganizationMembership.active.select(:user_id)
      ).count
      duplicate_memberships = OrganizationMembership.group(:user_id, :organization_id).having("COUNT(*) > 1").count.length
      organization_mismatches = User.where.not(organization_id: nil).where.not(id: pending_user_ids).where.not(
        id: OrganizationMembership.select(:user_id).where("organization_memberships.organization_id = users.organization_id")
      ).count

      {
        valid: users_without_membership.zero? && duplicate_memberships.zero? && organization_mismatches.zero?,
        users: User.count,
        memberships: OrganizationMembership.count,
        pending_registration_users: User.where(id: pending_user_ids).count,
        users_without_membership:,
        duplicate_memberships:,
        organization_mismatches:
      }
    end

    private

    def pending_registration_user_ids(now:)
      OrganizationInvite
        .joins(:email_authentications)
        .where(organization_invites: { used_at: nil })
        .where.not(organization_invites: { stand_by_user_id: nil })
        .where("organization_invites.stand_by_at > ?", Auth::MagicLinks::REGISTRATION_STAND_BY_WINDOW.ago(now))
        .where(email_authentications: { purpose: "registration", used_at: nil })
        .where("email_authentications.expires_at > ?", now)
        .select(:stand_by_user_id)
        .distinct
    end
  end
end
