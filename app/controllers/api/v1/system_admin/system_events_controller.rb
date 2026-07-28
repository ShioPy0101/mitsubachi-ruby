class Api::V1::SystemAdmin::SystemEventsController < Api::V1::SystemAdmin::BaseController
  def index
    render_collection(filtered_scope.order(occurred_at: :desc, id: :desc), method(:system_event_json))
  end

  def show
    event = SystemEvent.find_by(id: params[:id])
    return render_not_found if event.nil?

    render json: { data: system_event_json(event) }
  end

  private

  def filtered_scope
    scope = SystemEvent.all
    %i[organization_id severity source event_type job_id trace_id].each do |key|
      scope = scope.where(key => params[key]) if params[key].present?
    end
    request_id = request.query_parameters["request_id"]
    scope = scope.where(request_id: request_id) if request_id.present?
    scope = scope.where("occurred_at >= ?", Time.zone.parse(params[:occurred_from])) if params[:occurred_from].present?
    scope = scope.where("occurred_at <= ?", Time.zone.parse(params[:occurred_to])) if params[:occurred_to].present?
    scope
  rescue ArgumentError
    scope.none
  end

  def system_event_json(event)
    {
      id: event.id, organization_id: event.organization_id, event_type: event.event_type,
      severity: event.severity, source: event.source,
      target: { type: event.target_type, id: event.target_id }, related_user_id: event.related_user_id,
      request_id: event.request_id, job_id: event.job_id, trace_id: event.trace_id,
      error_class: event.error_class, error_message: event.error_message,
      metadata: event.metadata, occurred_at: event.occurred_at
    }
  end
end
