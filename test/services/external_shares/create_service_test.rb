require "test_helper"
require "digest"

class ExternalShares::CreateServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @organization = @user.organization
    @folder = drive_items(:child_folder)
    @file = drive_items(:child_file)
    @nested_file = DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      parent: @folder,
      name: "nested",
      item_type: "file",
      extension: "txt",
      storage_key: "nested-#{SecureRandom.uuid}.txt",
      blob_path: "drive_items/nested.txt",
      file_hash: Digest::SHA256.hexdigest("nested"),
      file_size: 6,
      content_type: "text/plain"
    )
  end

  test "複数のDriveItemを1つのsnapshot共有として作成する" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "納品データ",
        drive_item_ids: [ @folder.id, @file.id, @nested_file.id ],
        folder_share_mode: "snapshot",
        allow_download: true,
        allow_bulk_download: true
      }
    ).call

    assert result.success?
    share = result.external_share
    assert_predicate result.raw_token, :present?
    assert_equal "snapshot", share.folder_share_mode

    expected_ids = [
      @file,
      @folder,
      drive_items(:grandchild_folder),
      @nested_file
    ].map(&:id).sort
    actual_ids = share.external_share_items.pluck(:drive_item_id).sort

    assert_equal expected_ids, actual_ids
    assert_equal actual_ids.uniq, actual_ids
    assert_not_includes actual_ids, drive_items(:one).id
  end

  test "dynamic共有では選択されたルートだけを保存する" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "追従共有",
        drive_item_ids: [ @folder.id ],
        folder_share_mode: "dynamic"
      }
    ).call

    assert result.success?
    assert_equal [ @folder.id ], result.external_share.external_share_items.pluck(:drive_item_id)
  end

  test "他organizationのDriveItemが混在すると作成しない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "invalid",
        drive_item_ids: [ @file.id, drive_items(:two).id ],
        folder_share_mode: "snapshot"
      }
    ).call

    assert_not result.success?
    assert_equal :not_found, result.status
    assert_equal 0, ExternalShare.count
  end

  test "生トークンはDBへ保存しない" do
    result = ExternalShares::CreateService.new(
      user: @user,
      params: {
        name: "token",
        drive_item_ids: [ @file.id ],
        folder_share_mode: "snapshot"
      }
    ).call

    assert result.success?
    assert_not_equal result.raw_token, result.external_share.token_digest
    assert_equal Digest::SHA256.hexdigest(result.raw_token), result.external_share.token_digest
  end
end
