require "test_helper"

class OperationLogs::RecorderTest < ActiveSupport::TestCase
  test "records actor organization and target snapshots" do
    actor = users(:one)
    organization = organizations(:one)
    target = drive_items(:one)

    log = OperationLogs::Recorder.record!(
      operation_type: "drive_item.deleted",
      actor_user: actor,
      organization: organization,
      target: target
    )

    assert_equal target.class.name, log.metadata["target_type"]
    assert_equal target.id, log.metadata["target_id"]
    assert_equal target.filename, log.metadata["target_name"]
    assert log.metadata["target_path"].end_with?(target.filename)
    assert_equal organization.name, log.metadata["organization_name"]
    assert_equal actor.email, log.metadata["actor_email"]
    assert_equal actor.display_name, log.metadata["actor_display_name"]
  end


  test "canonical snapshots cannot be overwritten by caller metadata" do
    target = drive_items(:one)

    log = OperationLogs::Recorder.record!(
      operation_type: "drive_item.deleted",
      target: target,
      metadata: { target_name: "incorrect", target_id: -1 }
    )

    assert_equal target.filename, log.metadata["target_name"]
    assert_equal target.id, log.metadata["target_id"]
  end
end
