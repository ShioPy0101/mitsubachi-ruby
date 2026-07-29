require "test_helper"

class UploadMetrics::MaintenanceJobTest < ActiveJob::TestCase
  test "放置セッションをabandonedにし保持期間超過分を削除する" do
    stale = create_metric(started_at: 3.hours.ago, last_observed_at: 3.hours.ago)
    recent = create_metric(started_at: 1.hour.ago, last_observed_at: 1.hour.ago)
    old = create_metric(started_at: 181.days.ago, last_observed_at: 181.days.ago, status: "completed")

    UploadMetrics::MaintenanceJob.perform_now

    assert_equal "abandoned", stale.reload.status
    assert_equal "in_progress", recent.reload.status
    assert_not UploadMetric.exists?(old.id)
  end

  private

  def create_metric(started_at:, last_observed_at:, status: "in_progress")
    UploadMetric.create!(upload_session_id: SecureRandom.uuid, organization: organizations(:one),
      user: users(:one), started_at: started_at, last_observed_at: last_observed_at,
      status: status, upload_kind: "single")
  end
end
