require "test_helper"

class ApplicationJobTest < ActiveSupport::TestCase
  class FailingJob < ApplicationJob
    def perform(user)
      raise "job failed for #{user.id}"
    end
  end

  test "final job failure records a correlated system event and reraises" do
    error = assert_raises(RuntimeError) { FailingJob.perform_now(users(:one)) }

    event = SystemEvent.find_by!(event_type: "background_job.failed")
    assert_equal "worker", event.source
    assert_equal "error", event.severity
    assert_equal users(:one), event.related_user
    assert_equal users(:one).organization, event.organization
    assert event.job_id.present?
    assert_equal error.class.name, event.error_class
  end
end
