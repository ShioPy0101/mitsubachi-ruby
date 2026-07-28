module LogMigrations
  class OperationLogBackfill
    DEFAULT_BATCH_SIZE = 1_000
    OPERATION_TYPE_MAP = {
      "auth.registration_link.create" => "auth.registration_link_requested",
      "auth.login_link.create" => "auth.login_link_requested",
      "auth.verify" => "auth.verification_failed",
      "auth.registration.verify" => "auth.registration_verified",
      "auth.login.verify" => "auth.login_succeeded",
      "user.profile.update" => "user.profile_updated",
      "user.email_change.request" => "user.email_change_requested",
      "user.email_change.confirm" => "user.email_changed",
      "user.email_change.cancel" => "user.email_change_cancelled",
      "user.email_change.failure" => "user.email_change_failed",
      "organization.membership.create" => "organization.membership_created",
      "group.update" => "organization.settings_updated",
      "organization.create" => "organization.created",
      "organization.update" => "organization.settings_updated",
      "organization_invite.create" => "organization.invitation_created",
      "user.update" => "user.updated",
      "user.role_change" => "organization.membership_role_changed",
      "user.suspend" => "user.suspended",
      "user.unsuspend" => "user.unsuspended",
      "drive_item.create" => "drive_item.created",
      "drive_item.update" => "drive_item.updated",
      "drive_item.move" => "drive_item.moved",
      "drive_item.delete" => "drive_item.deleted",
      "drive_item.restore" => "drive_item.restored",
      "drive_item.purge" => "drive_item.purged",
      "drive_item.replace_trashed" => "drive_item.replaced_from_trash",
      "drive_item.bulk_move" => "drive_item.bulk_moved",
      "drive_item.bulk_delete" => "drive_item.bulk_deleted",
      "drive_item.bulk_restore" => "drive_item.bulk_restored",
      "drive_item.bulk_purge" => "drive_item.bulk_purged",
      "flower.device_authorization.created" => "flower.device_authorization_created",
      "flower.authorization.approved" => "flower.authorization_approved",
      "flower.authorization.denied" => "flower.authorization_denied",
      "flower.token.issued" => "flower.token_issued",
      "flower.drive_item.listed" => "flower.drive_items_listed",
      "flower.drive_item.viewed" => "flower.drive_item_viewed",
      "flower.download.denied" => "flower.download_denied"
    }.freeze

    Result = Data.define(:processed_count, :updated_count)

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      processed_count = 0
      updated_count = 0

      OperationLog.in_batches(of: @batch_size) do |relation|
        relation.each do |operation_log|
          processed_count += 1
          attributes = backfill_attributes(operation_log)
          next if attributes.empty?

          operation_log.update_columns(attributes)
          updated_count += 1
        end
      end

      Result.new(processed_count, updated_count)
    end

    private

    def backfill_attributes(operation_log)
      attributes = {}
      mapped_type = OPERATION_TYPE_MAP.fetch(operation_log.operation_type, operation_log.operation_type)
      attributes[:operation_type] = mapped_type if mapped_type != operation_log.operation_type

      actor_attributes(operation_log).each do |key, value|
        attributes[key] = value if operation_log.public_send(key) != value
      end
      attributes
    end

    def actor_attributes(operation_log)
      return { actor_kind: "user", actor_external_share_id: nil } if operation_log.actor_user_id.present?

      external_share_id = operation_log.metadata.to_h["external_share_id"]
      if external_share_id.present? && ExternalShare.exists?(id: external_share_id)
        return { actor_kind: "external_share", actor_external_share_id: external_share_id }
      end

      { actor_kind: "anonymous", actor_external_share_id: nil }
    end
  end
end
