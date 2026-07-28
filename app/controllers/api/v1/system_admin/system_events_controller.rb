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
    event.attributes.slice(
      "id", "event_type", "severity", "source", "organization_id", "related_user_id",
      "target_type", "target_id", "request_id", "job_id", "trace_id", "error_class",
      "error_message", "metadata", "occurred_at", "created_at"
    )
  end
end
