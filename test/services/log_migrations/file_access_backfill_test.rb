require "test_helper"

class LogMigrations::FileAccessBackfillTest < ActiveSupport::TestCase
  test "request_idが一致する既存アクセスを重複させずOperationLogを削除する" do
    existing = drive_item_access_logs(:one)
    existing.update!(request_id: "same-request", actor_kind: "user")
    operation_log = OperationLog.create!(
      actor_kind: "user",
      actor_user: existing.user,
      organization: existing.organization,
      operation_type: "drive_item.preview",
      result: "success",
      target_type: "DriveItem",
      target_id: existing.drive_item_id,
      request_id: "same-request",
      ip_address: existing.ip_address,
      occurred_at: existing.occurred_at
    )

    result = nil
    assert_no_difference "DriveItemAccessLog.count" do
      result = LogMigrations::FileAccessBackfill.new(batch_size: 1).call
    end

    assert_not OperationLog.exists?(operation_log.id)
    assert_equal 1, result.deduplicated_count
    assert_equal 1, result.removed_count
  end

  test "外部共有アクセスをuserなしで移行する" do
    share = ExternalShare.create!(
      organization: organizations(:one),
      created_by_user: users(:one),
      name: "Migration share",
      token_digest: Digest::SHA256.hexdigest("migration-share-token"),
      allow_download: true,
      allow_bulk_download: false,
      folder_share_mode: "snapshot"
    )
    item = drive_items(:child_file)
    operation_log = OperationLog.create!(
      actor_kind: "external_share",
      actor_external_share: share,
      organization: share.organization,
      operation_type: "external_share.file_previewed",
      result: "success",
      target_type: "ExternalShare",
      target_id: share.id,
      request_id: "external-preview",
      ip_address: "203.0.113.40",
      metadata: { external_share_id: share.id, drive_item_id: item.id },
      occurred_at: Time.current
    )

    assert_difference "DriveItemAccessLog.count", 1 do
      LogMigrations::FileAccessBackfill.new.call
    end

    log = DriveItemAccessLog.find_by!(request_id: "external-preview")
    assert_equal "external_share", log.actor_kind
    assert_equal share, log.external_share
    assert_nil log.user
    assert_not OperationLog.exists?(operation_log.id)
  end
end
