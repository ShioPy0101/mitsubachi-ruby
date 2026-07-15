require "test_helper"

class DriveItemAccessLogTest < ActiveSupport::TestCase
  test "for organization scope filters other organizations" do
    logs = DriveItemAccessLog.for_organization(organizations(:one))

    assert_includes logs, drive_item_access_logs(:one)
    assert_not_includes logs, drive_item_access_logs(:two)
  end
end
