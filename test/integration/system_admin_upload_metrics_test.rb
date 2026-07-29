require "test_helper"

class SystemAdminUploadMetricsTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @admin.update!(role: :system_admin)
    sign_in @admin
    create_metric(organization: organizations(:one), status: "completed", bytes: 100, files: 2, completed: 2, throughput: 10, elapsed: 100)
    create_metric(organization: organizations(:two), status: "completed_with_errors", bytes: 300, files: 3, completed: 2, failed: 1, throughput: 30, elapsed: 300)
  end

  test "system adminだけが全Organizationの一覧をページネーションできる" do
    get "/api/v1/system_admin/upload_metrics", params: { period: "24h", per_page: 1 }
    assert_response :ok
    assert_equal 1, response.parsed_body["data"].length
    assert_equal 2, response.parsed_body.dig("meta", "total_count")

    sign_in users(:two)
    get "/api/v1/system_admin/upload_metrics"
    assert_response :forbidden
  end

  test "summaryと一覧で同じOrganization条件を使いp50とp95を返す" do
    get "/api/v1/system_admin/upload_metrics/summary", params: { period: "24h", organization_id: organizations(:two).id }
    assert_response :ok
    data = response.parsed_body["data"]
    assert_equal 1, data["session_count"]
    assert_equal 300, data["total_bytes"]
    assert_equal 30, data["p50_throughput_bytes_per_second"]
    assert_equal 300, data["p95_elapsed_ms"]

    sign_in @admin
    get "/api/v1/system_admin/upload_metrics", params: { period: "24h", organization_id: organizations(:two).id }
    assert_response :ok
    assert_equal 1, response.parsed_body.dig("meta", "total_count")
  end

  test "時系列と詳細にファイル名を含めない" do
    get "/api/v1/system_admin/upload_metrics/timeseries", params: { period: "24h" }
    assert_response :ok
    assert_equal 2, response.parsed_body.dig("data", 0, "session_count")

    metric = UploadMetric.first
    sign_in @admin
    get "/api/v1/system_admin/upload_metrics/#{metric.upload_session_id}"
    assert_response :ok
    refute_includes response.body, "filename"
    refute_includes response.body, "relative_path"
  end

  private

  def create_metric(organization:, status:, bytes:, files:, completed:, throughput:, elapsed:, failed: 0)
    UploadMetric.create!(upload_session_id: SecureRandom.uuid, organization: organization,
      user: organization.users.first || @admin, upload_kind: "multiple", status: status,
      started_at: 1.hour.ago, completed_at: Time.current, last_observed_at: Time.current,
      total_files: files, total_bytes: bytes, completed_files: completed,
      completed_bytes: bytes, failed_files: failed,
      effective_throughput_bytes_per_second: throughput, elapsed_ms: elapsed)
  end
end
