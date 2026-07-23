require "test_helper"

class DriveItemTest < ActiveSupport::TestCase
  setup do
    @active = drive_items(:one)
    @trashed = drive_items(:deleted_folder)
    @purged = drive_items(:deleted_report)
    @purged.update_columns(purged_at: Time.current)
  end

  test "active は通常状態だけを返す" do
    assert_includes DriveItem.active, @active
    assert_not_includes DriveItem.active, @trashed
    assert_not_includes DriveItem.active, @purged
  end

  test "trashed はゴミ箱状態だけを返す" do
    assert_includes DriveItem.trashed, @trashed
    assert_not_includes DriveItem.trashed, @active
    assert_not_includes DriveItem.trashed, @purged
  end

  test "purged は完全削除済み状態だけを返す" do
    assert_equal [ @purged.id ], DriveItem.purged.where(id: [ @active, @trashed, @purged ]).pluck(:id)
  end

  test "not_purged は完全削除済み状態を除外する" do
    assert_includes DriveItem.not_purged, @active
    assert_includes DriveItem.not_purged, @trashed
    assert_not_includes DriveItem.not_purged, @purged
  end
end
