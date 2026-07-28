require "test_helper"

class SystemEvents::RecorderTest < ActiveSupport::TestCase
  test "severity source correlation and sanitized metadata are stored" do
    error = StandardError.new("failed at /Users/example/private/file.txt")

    event = SystemEvents::Recorder.record!(
      event_type: "storage.delivery_preparation_failed",
      severity: "error",
      source: "storage",
      organization: organizations(:one),
      related_user: users(:one),
      target: drive_items(:child_file),
      request_id: "request-1",
      job_id: "job-1",
      trace_id: "trace-1",
      error: error,
      metadata: {
        Authorization: "Bearer secret",
        nested: { refresh_token: "raw-token", safe: "value" },
        path: "/private/tmp/secret.txt"
      }
    )

    assert_equal "error", event.severity
    assert_equal "storage", event.source
    assert_equal organizations(:one), event.organization
    assert_equal users(:one), event.related_user
    assert_equal "request-1", event.request_id
    assert_equal "job-1", event.job_id
    assert_equal "trace-1", event.trace_id
    assert_equal "[FILTERED]", event.metadata["Authorization"]
    assert_equal "[FILTERED]", event.metadata.dig("nested", "refresh_token")
    assert_equal "value", event.metadata.dig("nested", "safe")
    assert_equal "[FILTERED_PATH]", event.metadata["path"]
    assert_not_includes event.error_message, "/Users/"
  end

  test "recorder failure does not break the caller or recursively persist" do
    original_create = SystemEvent.method(:create!)
    SystemEvent.define_singleton_method(:create!) { |**| raise ActiveRecord::ConnectionNotEstablished, "database unavailable" }

    assert_no_difference "SystemEvent.count" do
      assert_nil SystemEvents::Recorder.record!(
        event_type: "application.test_failed",
        severity: "error",
        source: "application"
      )
    end
  ensure
    SystemEvent.define_singleton_method(:create!, original_create)
  end
end
