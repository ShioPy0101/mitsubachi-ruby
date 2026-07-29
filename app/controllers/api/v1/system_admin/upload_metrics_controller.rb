class Api::V1::SystemAdmin::UploadMetricsController < Api::V1::SystemAdmin::BaseController
  MAX_RANGE = 366.days
  MAX_PER_PAGE = 100
  STATUSES = UploadMetric::STATUSES.freeze

  before_action :set_range, only: %i[index summary timeseries]

  def index
    scope = filtered_scope.includes(:organization, :user).order(started_at: :desc)
    page = [ params[:page].to_i, 1 ].max
    per_page = params[:per_page].presence.to_i.clamp(1, MAX_PER_PAGE)
    per_page = 20 if params[:per_page].blank?
    total = scope.count
    render json: {
      data: scope.offset((page - 1) * per_page).limit(per_page).map { |metric| serialize(metric) },
      meta: { current_page: page, per_page: per_page,
              total_pages: [ (total.to_f / per_page).ceil, 1 ].max, total_count: total }
    }
  end

  def show
    metric = UploadMetric.includes(:organization, :user).find_by!(upload_session_id: params[:id])
    related_operations = OperationLog.where(operation_type: %w[upload.metric_started upload.metric_completed upload.metric_problem])
                                     .where("metadata ->> 'upload_session_id' = ?", metric.upload_session_id.to_s)
                                     .order(occurred_at: :asc)
    render json: { data: serialize(metric).merge(
      related_operation_logs: related_operations.map { |log| { id: log.id, operation_type: log.operation_type,
        result: log.result, request_id: log.request_id, occurred_at: log.occurred_at } },
      request_ids: metric.request_ids) }
  end

  def summary
    scope = filtered_scope
    aggregate = scope.pick(
      Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(total_bytes),0)"),
      Arel.sql("COALESCE(SUM(total_files),0)"),
      Arel.sql("COUNT(*) FILTER (WHERE status='completed')"),
      Arel.sql("COUNT(*) FILTER (WHERE status='failed')"),
      Arel.sql("COUNT(*) FILTER (WHERE status='completed_with_errors')"),
      Arel.sql("COUNT(*) FILTER (WHERE status='abandoned')"),
      Arel.sql("COALESCE(SUM(failed_files),0)"), Arel.sql("COALESCE(SUM(retry_count),0)"),
      Arel.sql("COALESCE(SUM(retried_files),0)"), Arel.sql("COALESCE(SUM(completed_files + failed_files),0)"),
      Arel.sql("COALESCE(AVG(NULLIF(effective_throughput_bytes_per_second,0)),0)"),
      Arel.sql("COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY NULLIF(effective_throughput_bytes_per_second,0)),0)"),
      Arel.sql("COALESCE(percentile_cont(0.95) WITHIN GROUP (ORDER BY NULLIF(elapsed_ms,0)),0)"),
      Arel.sql("COALESCE(MAX(total_bytes),0)")
    )
    total, total_bytes, total_files, completed, failed, partial, abandoned,
      failed_files, retry_count, retried_files, attempted_files, average_throughput,
      p50_throughput, p95_elapsed, max_bytes = aggregate
    render json: { data: {
      range: range_json, session_count: total.to_i, total_bytes: total_bytes.to_i, total_files: total_files.to_i,
      session_success_rate: ratio(completed, total), failed_sessions: failed.to_i,
      partial_failure_sessions: partial.to_i, abandoned_sessions: abandoned.to_i,
      file_failure_rate: ratio(failed_files, attempted_files), retry_rate: ratio(retried_files, total_files),
      retry_count: retry_count.to_i, average_throughput_bytes_per_second: average_throughput.to_f.round,
      p50_throughput_bytes_per_second: p50_throughput.to_f.round,
      p95_elapsed_ms: p95_elapsed.to_f.round, max_upload_bytes: max_bytes.to_i
    } }
  end

  def timeseries
    bucket = (@to - @from) <= 48.hours ? "hour" : "day"
    rows = filtered_scope.group(Arel.sql("date_trunc('#{bucket}', started_at)"))
                         .order(Arel.sql("date_trunc('#{bucket}', started_at)"))
                         .pluck(
                           Arel.sql("date_trunc('#{bucket}', started_at)"),
                           Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(total_bytes),0)"),
                           Arel.sql("COALESCE(SUM(total_files),0)"),
                           Arel.sql("COUNT(*) FILTER (WHERE status='failed')"),
                           Arel.sql("COUNT(*) FILTER (WHERE status='completed_with_errors')"),
                           Arel.sql("COUNT(*) FILTER (WHERE status='abandoned')"),
                           Arel.sql("COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY NULLIF(effective_throughput_bytes_per_second,0)),0)"),
                           Arel.sql("COALESCE(percentile_cont(0.1) WITHIN GROUP (ORDER BY NULLIF(effective_throughput_bytes_per_second,0)),0)"),
                           Arel.sql("COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY NULLIF(elapsed_ms,0)),0)"),
                           Arel.sql("COALESCE(percentile_cont(0.95) WITHIN GROUP (ORDER BY NULLIF(elapsed_ms,0)),0)"),
                           Arel.sql("COALESCE(SUM(failed_files),0)"),
                           Arel.sql("COALESCE(SUM(completed_files + failed_files),0)"),
                           Arel.sql("COALESCE(SUM(retried_files),0)")
                         )
    render json: { data: rows.map { |row| timeseries_row(row) }, bucket: bucket, range: range_json }
  end

  private

  def set_range
    @to = parse_time(params[:to]) || Time.current
    @from = parse_time(params[:from]) || preset_duration.ago
    @from = @to - MAX_RANGE if @to - @from > MAX_RANGE
  end

  def preset_duration
    { "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.fetch(params[:period], 24.hours)
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def filtered_scope
    scope = UploadMetric.where(started_at: @from..@to)
    scope = scope.where(organization_id: params[:organization_id]) if params[:organization_id].present?
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = scope.where(status: params[:status]) if params[:status].in?(STATUSES)
    scope = scope.where(upload_kind: params[:upload_kind]) if params[:upload_kind].in?(UploadMetric::KINDS)
    scope = scope.where("total_bytes >= ?", bounded_integer(params[:minimum_bytes], UploadMetric::MAX_BYTES)) if params[:minimum_bytes].present?
    scope = scope.where("total_files >= ?", bounded_integer(params[:minimum_files], UploadMetric::MAX_FILES)) if params[:minimum_files].present?
    scope = scope.where("error_code_counts ? ?", params[:error_code].to_s.first(100)) if params[:error_code].present?
    apply_size_band(scope)
  end

  def apply_size_band(scope)
    column = { "under_1mb" => :under_1mb_count, "1mb_to_100mb" => :between_1mb_and_100mb_count,
               "100mb_to_1gb" => :between_100mb_and_1gb_count, "over_1gb" => :over_1gb_count }[params[:size_band]]
    column ? scope.where("#{column} > 0") : scope
  end

  def bounded_integer(value, maximum)
    value.to_i.clamp(0, maximum)
  end

  def serialize(metric)
    metric.as_json(except: %i[id user_id request_ids], methods: []).merge(
      organization_name: metric.organization.name, user_id: metric.user_id,
      user_name: metric.user.safe_display_name, needs_review: needs_review?(metric)
    )
  end

  def needs_review?(metric)
    reasons = []
    reasons << "状態" if %w[failed completed_with_errors abandoned].include?(metric.status)
    attempts = metric.completed_files + metric.failed_files
    reasons << "ファイル失敗率" if attempts.positive? && metric.failed_files.fdiv(attempts) >= threshold("UPLOAD_METRIC_FAILURE_RATE_THRESHOLD", 0.05)
    reasons << "再試行率" if metric.total_files.positive? && metric.retried_files.fdiv(metric.total_files) >= threshold("UPLOAD_METRIC_RETRY_RATE_THRESHOLD", 0.1)
    reasons << "進捗停止" if metric.progress_stall_count.positive?
    slow = ENV.fetch("UPLOAD_METRIC_LOW_THROUGHPUT_BPS", "0").to_i
    reasons << "低スループット" if slow.positive? && metric.effective_throughput_bytes_per_second.between?(1, slow - 1)
    reasons
  end

  def threshold(name, default)
    Float(ENV.fetch(name, default.to_s))
  rescue ArgumentError
    default
  end

  def timeseries_row(row)
    bucket, sessions, bytes, files, failed, partial, abandoned, p50_bps, p10_bps,
      p50_ms, p95_ms, failed_files, attempted_files, retried_files = row
    { bucket: bucket, session_count: sessions.to_i, total_bytes: bytes.to_i, total_files: files.to_i,
      failed_sessions: failed.to_i, partial_failure_sessions: partial.to_i, abandoned_sessions: abandoned.to_i,
      p50_throughput_bytes_per_second: p50_bps.to_f.round,
      p10_throughput_bytes_per_second: p10_bps.to_f.round,
      p50_elapsed_ms: p50_ms.to_f.round, p95_elapsed_ms: p95_ms.to_f.round,
      file_failure_rate: ratio(failed_files, attempted_files), retry_rate: ratio(retried_files, files) }
  end

  def ratio(numerator, denominator)
    denominator.to_i.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
  end

  def range_json
    { from: @from.iso8601, to: @to.iso8601 }
  end
end
