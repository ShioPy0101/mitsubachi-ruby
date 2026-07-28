class Api::V1::Admin::SystemEventsController < Api::V1::Admin::BaseController
  def index
    render_collection(filtered_scope.order(occurred_at: :desc, id: :desc), method(:system_event_json))
  end

  def show
    event = scoped_system_events.find_by(id: params[:id])
    return render_not_found if event.nil?

    render json: { data: system_event_json(event) }
  end

  private

  def filtered_scope
    scope = scoped_system_events
    %i[severity source event_type job_id trace_id].each do |key|
      scope = scope.where(key => params[key]) if params[key].present?
    end
    request_id = request.query_parameters["request_id"]
    scope = scope.where(request_id: request_id) if request_id.present?
    scope = scope.where("system_events.occurred_at >= ?", Time.zone.parse(params[:occurred_from])) if params[:occurred_from].present?
    scope = scope.where("system_events.occurred_at <= ?", Time.zone.parse(params[:occurred_to])) if params[:occurred_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def system_event_json(event)
    {
      id: event.id, event_type: event.event_type, severity: event.severity, source: event.source,
      organization_id: event.organization_id, related_user_id: event.related_user_id,
      target_type: event.target_type, target_id: event.target_id, request_id: event.request_id,
      job_id: event.job_id, trace_id: event.trace_id, occurred_at: event.occurred_at,
      metadata: {}
    }
  end
end
