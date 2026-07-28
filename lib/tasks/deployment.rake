require "json"
require "fileutils"
require "pathname"

namespace :deployment do
  desc "migration前の主要レコード件数をJSONへ保存する"
  task pre_migration_snapshot: :environment do
    output = required_output_path!
    payload = {
      generated_at: Time.current.iso8601,
      users: User.count,
      organizations: Organization.count,
      organization_memberships: OrganizationMembership.count,
      active_organization_memberships: OrganizationMembership.active.count,
      drive_items: DriveItem.count
    }
    write_private_json!(output, payload)
  end

  desc "organization membership移行後の整合性を検証してJSONへ保存する"
  task verify_migration: :environment do
    output = required_output_path!
    duplicate_memberships = OrganizationMembership.group(:user_id, :organization_id).having("COUNT(*) > 1").count.length
    users_without_membership = User.where.not(role: User.roles[:system_admin]).where.not(
      id: OrganizationMembership.active.select(:user_id)
    ).count
    organization_mismatches = User.where.not(organization_id: nil).where.not(
      id: OrganizationMembership.select(:user_id).where("organization_memberships.organization_id = users.organization_id")
    ).count
    payload = {
      valid: users_without_membership.zero? && duplicate_memberships.zero? && organization_mismatches.zero?,
      users: User.count,
      memberships: OrganizationMembership.count,
      users_without_membership:,
      duplicate_memberships:,
      organization_mismatches:
    }
    write_private_json!(output, payload)
    abort "migration verification failed" unless payload[:valid]
  end

  desc "本番スモークテスト専用の短寿命ログイントークンをJSONへ保存する"
  task prepare_smoke_test_credentials: :environment do
    output = required_output_path!
    write_private_json!(output, Deployment::SmokeTestCredentials.new.call)
  end
end

def required_output_path!
  output = ENV.fetch("OUTPUT", "").strip
  abort "OUTPUT is required" if output.empty?

  Pathname.new(output)
end

def write_private_json!(output, payload)
  FileUtils.mkdir_p(output.dirname)
  File.write(output, JSON.pretty_generate(payload))
  File.chmod(0o600, output)
end
