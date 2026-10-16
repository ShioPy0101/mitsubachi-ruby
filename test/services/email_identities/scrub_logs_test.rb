require "test_helper"

class EmailIdentities::ScrubLogsTest < ActiveSupport::TestCase
  test "scrubs existing historical email snapshots without dropping audit records" do
    log = OperationLogs::Recorder.record!(operation_type: "user.updated", actor_user: users(:one))
    log.update_columns(metadata: { actor_email: "old@example.com", nested: { description: "rejected old@example.com" } }, change_set: { email: [ "old@example.com", "new@example.com" ] })
    event = SystemEvents::Recorder.record!(event_type: "mail.delivery_failed", severity: "error", source: "mailer")
    event.update_columns(error_message: "rejected old@example.com", metadata: { recipient: "old@example.com" })
    2.times { EmailIdentities::ScrubLogs.new.call }
    refute_includes log.reload.attributes.to_json, "@example.com"
    refute_includes event.reload.attributes.to_json, "@example.com"
    assert_equal users(:one).id, log.actor_user_id
    assert_equal "user.updated", log.operation_type
  end
end
