require "test_helper"

class UploadMetricsApiTest < ActionDispatch::IntegrationTest
  UUID = "123e4567-e89b-42d3-a456-426614174000"

  setup do
    @user = users(:one)
    sign_in @user
  end

  test "未認証では通常アップロード統計を登録できない" do
    sign_out @user
    post "/api/v1/upload_metrics", params: valid_params
    assert_response :unauthorized
  end

  test "作成と更新はUUIDで冪等になり所属を偽装できない" do
    2.times do
      sign_in @user
      post "/api/v1/upload_metrics", params: valid_params.merge(
        organization_id: organizations(:two).id, user_id: users(:two).id
      )
      assert_response :success
    end
    metric = UploadMetric.find_by!(upload_session_id: UUID)
    assert_equal organizations(:one), metric.organization
    assert_equal @user, metric.user

    sign_in @user
    patch "/api/v1/upload_metrics/#{UUID}", params: { status: "completed", completed_files: 2, completed_bytes: 30 }
    assert_response :ok
    assert_equal "completed", metric.reload.status
  end

  test "選択Organization境界を越えて更新できない" do
    metric = UploadMetric.create!(valid_attributes.merge(upload_session_id: UUID,
      organization: organizations(:two), user: users(:two)))
    patch "/api/v1/organizations/#{organizations(:one).id}/upload_metrics/#{metric.upload_session_id}",
          params: { status: "completed" }
    assert_response :not_found
  end

  test "UUIDと負数と巨大値を拒否する" do
    post "/api/v1/upload_metrics", params: valid_params.merge(upload_session_id: "bad\nvalue")
    assert_response :unprocessable_entity
    sign_in @user
    post "/api/v1/upload_metrics", params: valid_params.merge(total_files: -1)
    assert_response :unprocessable_entity
    sign_in @user
    post "/api/v1/upload_metrics", params: valid_params.merge(total_bytes: 11.petabytes)
    assert_response :unprocessable_entity
  end

  test "巨大payloadを拒否し完了後の遅延定期更新で状態を戻さない" do
    post "/api/v1/upload_metrics", params: valid_params.merge(metadata: { note: "x" * 70.kilobytes })
    assert_response :content_too_large

    sign_in @user
    post "/api/v1/upload_metrics", params: valid_params
    assert_response :created
    sign_in @user
    patch "/api/v1/upload_metrics/#{UUID}", params: { status: "completed", completed_files: 2 }
    assert_response :ok
    sign_in @user
    patch "/api/v1/upload_metrics/#{UUID}", params: { status: "in_progress", completed_files: 1 }
    assert_response :ok
    assert_equal "completed", UploadMetric.find_by!(upload_session_id: UUID).status
  end

  private

  def valid_params
    valid_attributes.merge(upload_session_id: UUID)
  end

  def valid_attributes
    { upload_kind: "multiple", status: "in_progress", started_at: Time.current,
      last_observed_at: Time.current, total_files: 2, total_bytes: 30,
      max_concurrency: 4 }
  end
end
