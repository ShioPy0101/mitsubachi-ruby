module Deployment
  class SmokeTestCredentials
    TOKEN_TTL = 15.minutes
    EMAIL_DOMAIN = "example.invalid"
    ORGANIZATION_NAME = "Mitsubachi Production Smoke Test"

    def call
      ActiveRecord::Base.transaction do
        organization = Organization.find_or_create_by!(name: ORGANIZATION_NAME)
        secondary_organization = Organization.find_or_create_by!(name: "#{ORGANIZATION_NAME} Secondary")

        {
          generated_at: Time.current.iso8601,
          expires_at: TOKEN_TTL.from_now.iso8601,
          users: {
            member: prepare_user!("member", organization:, memberships: [ [ organization, :member ], [ secondary_organization, :member ] ]),
            organization_admin: prepare_user!("organization-admin", organization:, memberships: [ [ organization, :organization_admin ] ]),
            system_admin: prepare_user!("system-admin", organization:, system_admin: true, memberships: [ [ organization, :member ] ])
          },
          organizations: {
            primary_id: organization.id,
            secondary_id: secondary_organization.id
          }
        }
      end
    end

    private

    def prepare_user!(name, organization:, memberships:, system_admin: false)
      email = "mitsubachi-smoke-#{name}@#{EMAIL_DOMAIN}"
      user = User.find_or_initialize_by(email:)
      user.organization = organization
      user.display_name = "Smoke #{name.tr('-', ' ').titleize}"
      user.role = system_admin ? :system_admin : :member
      user.suspended_at = nil
      user.password = SecureRandom.base64(32) if user.new_record?
      user.save!

      memberships.each do |membership_organization, role|
        membership = OrganizationMembership.find_or_initialize_by(user:, organization: membership_organization)
        membership.update!(role:, status: :active, joined_at: membership.joined_at || Time.current)
      end

      authentication = Auth::MagicLinks.new.request_login(email:)
      { email:, token: authentication.token }
    end
  end
end
