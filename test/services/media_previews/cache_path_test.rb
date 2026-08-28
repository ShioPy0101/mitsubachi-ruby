require "test_helper"

class MediaPreviewsCachePathTest < ActiveSupport::TestCase
  test "cache pathは認可済みDriveItemのIDと固定versionだけで安全に決まる" do
    item = drive_items(:child_file)
    path = MediaPreviews::CachePath.new(drive_item: item)

    assert path.absolute_path.to_s.start_with?(DriveItem.storage_root.join("previews").to_s)
    assert_match %r{/previews/organization-#{item.organization_id}/drive-item-#{item.id}/v1/320-[0-9a-f]{16}\.jpg\z}, path.absolute_path.to_s
    assert_match %r{\A/internal/previews/organization-#{item.organization_id}/drive-item-#{item.id}/v1/}, path.internal_uri
    refute_includes path.absolute_path.to_s, item.filename
  end

  test "Original versionが変わるとcache pathとETagが変わる" do
    item = drive_items(:child_file)
    before = MediaPreviews::CachePath.new(drive_item: item)
    before_values = [ before.absolute_path, before.etag ]

    item.file_hash = Digest::SHA256.hexdigest("replacement")
    item.updated_at = 1.second.from_now
    after = MediaPreviews::CachePath.new(drive_item: item)

    refute_equal before_values, [ after.absolute_path, after.etag ]
  end
end
