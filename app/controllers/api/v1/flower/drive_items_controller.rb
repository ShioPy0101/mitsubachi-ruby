class Api::V1::Flower::DriveItemsController < Api::V1::Flower::BaseController
  before_action :rate_limit_download!, only: :download

  def index
    result = Flower::DriveItems::List.new(organization: current_organization, params: params).call
    record_flower_event!(
      "flower.drive_item.listed",
      metadata: {
        result: "success",
        query_present: params[:query].present?,
        returned_count: result.items.size,
        client_version: current_flower_token.flower_device_authorization&.client_metadata&.fetch("client_version", nil)
      }
    )

    render json: {
      items: result.items.map { |drive_item| Flower::DriveItems::Serializer.new(drive_item).list_json },
      pagination: {
        next_cursor: result.next_cursor
      }
    }
  end

  def show
    drive_item = Flower::DriveItems::Show.new(organization: current_organization, id: params[:id]).call
    return render_flower_not_found if drive_item.nil?

    record_flower_event!(
      "flower.drive_item.viewed",
      target: drive_item,
      metadata: { drive_item_id: drive_item.id, result: "success" }
    )
    render json: Flower::DriveItems::Serializer.new(drive_item).detail_json
  end

  def download
    authorization = Flower::Downloads::Authorize.new(
      organization: current_organization,
      token: current_flower_token,
      id: params[:id]
    ).call

    unless authorization.success?
      record_download_denied(authorization)
      render_flower_error(authorization.error_code, authorization.message, status: authorization.status)
      return
    end

    drive_item = authorization.drive_item
    result = DriveItems::DeliveryService.new(
      drive_item: drive_item,
      current_user: current_user,
      request: request,
      action: :download,
      client_type: "flower"
    ).call

    unless result.success?
      record_download_denied(result, drive_item: drive_item)
      render_flower_error(error_code_for_status(result.status), result.error_message, status: result.status)
      return
    end

    record_flower_event!(
      "flower.file.downloaded",
      target: drive_item,
      metadata: download_metadata(drive_item).merge(result: "success")
    )
    result.headers.each { |key, value| response.headers[key] = value }
    self.status = result.status
    self.response_body = ""
  end

  private

  def required_flower_scopes
    action_name == "download" ? [ "flower:download" ] : [ "flower:read" ]
  end

  def rate_limit_download!
    result = Security::RateLimiter.new(
      namespace: "flower-download-token",
      key: current_flower_token&.id || request.remote_ip,
      limit: 120,
      period: 1.minute
    ).call
    return if result.allowed?

    render_flower_error("rate_limited", "Too many download requests.", status: :too_many_requests)
  end

  def record_download_denied(result, drive_item: nil)
    record_flower_event!(
      "flower.download.denied",
      target: drive_item,
      outcome: "denied",
      metadata: {
        drive_item_id: drive_item&.id || params[:id],
        result: "denied",
        denial_reason: result.respond_to?(:error_code) ? result.error_code : error_code_for_status(result.status),
        downloaded_bytes: 0
      }
    )
  end

  def record_flower_event!(action, target: nil, outcome: "success", metadata: {})
    record_audit_event!(
      action: action,
      target: target,
      organization: current_organization,
      outcome: outcome,
      metadata: flower_metadata(metadata).merge(
        flower_access_token_id: current_flower_token&.id,
        device_authorization_id: current_flower_token&.flower_device_authorization_id
      )
    )
  end

  def download_metadata(drive_item)
    {
      drive_item_id: drive_item.id,
      file_hash: drive_item.file_hash,
      file_size: drive_item.file_size,
      downloaded_bytes: drive_item.file_size
    }
  end

  def error_code_for_status(status)
    case Rack::Utils.status_code(status)
    when 401 then "invalid_token"
    when 403 then "insufficient_scope"
    when 404 then "not_found"
    when 409 then "conflict"
    when 422 then "invalid_request"
    when 429 then "rate_limited"
    when 500..599 then "internal_error"
    else "invalid_request"
    end
  end
end
