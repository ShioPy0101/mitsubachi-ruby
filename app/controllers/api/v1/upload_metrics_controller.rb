class Api::V1::UploadMetricsController < ApplicationController
  MAX_PAYLOAD_BYTES = 64.kilobytes
  FIELDS = %i[
    upload_kind status started_at completed_at last_observed_at total_files total_bytes
    completed_files completed_bytes failed_files retried_files retry_count cancelled_files
    max_concurrency elapsed_ms effective_throughput_bytes_per_second min_file_size_bytes
    max_file_size_bytes average_file_size_bytes max_relative_depth under_1mb_count
    between_1mb_and_100mb_count between_100mb_and_1gb_count over_1gb_count
    progress_stall_count long_task_count long_task_total_duration_ms
    long_task_max_duration_ms background_duration_ms frontend_version http_status_counts
    error_code_counts metadata
    request_ids
  ].freeze

  before_action :authenticate_user!
  before_action :reject_large_payload!
  before_action :set_current_organization, if: :organization_path_scope?
  before_action :set_metric, only: :update

  def create
    uuid = normalized_uuid(params[:upload_session_id])
    return render_invalid_uuid unless uuid

    metric = UploadMetric.find_or_initialize_by(upload_session_id: uuid)
    if metric.persisted? && (metric.organization_id != current_organization.id || metric.user_id != current_user.id)
      raise ActiveRecord::RecordNotFound
    end

    metric.organization = current_organization
    metric.user = current_user
    metric.assign_attributes(metric_params)
    metric.status ||= "in_progress"
    metric.started_at ||= Time.current
    metric.last_observed_at = Time.current
    metric.backend_version ||= ENV.fetch("GIT_COMMIT_SHA", nil)
    metric.save!
    record_metric_operation(metric, "upload.metric_started") if metric.previously_new_record?
    render json: metric_json(metric), status: metric.previously_new_record? ? :created : :ok
  rescue ActiveRecord::RecordInvalid => error
    render_validation_failed(error.record)
  end

  def update
    previous_status = @metric.status
    attributes = metric_params.except("started_at", "last_observed_at")
    # 完了通知と入れ違いで到着した定期更新により、終端状態を戻さない。
    attributes.delete("status") if previous_status != "in_progress" && attributes["status"] == "in_progress"
    @metric.assign_attributes(attributes)
    @metric.last_observed_at = Time.current
    @metric.save!
    if previous_status == "in_progress" && @metric.status != "in_progress"
      record_metric_operation(@metric, @metric.status == "completed" ? "upload.metric_completed" : "upload.metric_problem")
    end
    render json: metric_json(@metric)
  rescue ActiveRecord::RecordInvalid => error
    render_validation_failed(error.record)
  end

  private

  def set_metric
    uuid = normalized_uuid(params[:upload_session_id])
    return render_invalid_uuid unless uuid

    @metric = current_organization.upload_metrics.find_by!(upload_session_id: uuid, user: current_user)
  end

  def current_organization
    super || current_user.organization_memberships.active.includes(:organization).first&.organization
  end

  def metric_params
    params.permit(*FIELDS, request_ids: [], http_status_counts: {}, error_code_counts: {}, metadata: {}).to_h
  end

  def normalized_uuid(value)
    uuid = value.to_s.downcase
    uuid if uuid.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
  end

  def render_invalid_uuid
    render_api_error(:validation_failed, "upload_session_idはUUID形式で指定してください", status: :unprocessable_content)
  end

  def reject_large_payload!
    return if request.content_length.to_i <= MAX_PAYLOAD_BYTES

    render_api_error(:payload_too_large, "アップロード統計が上限を超えています", status: :content_too_large)
  end

  def metric_json(metric)
    metric.as_json(except: %i[id user_id request_ids])
  end

  def record_metric_operation(metric, operation_type)
    record_operation!(operation_type: operation_type, target: metric,
                      metadata: { upload_session_id: metric.upload_session_id, status: metric.status })
  end
end
