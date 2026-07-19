class Api::V1::Flower::DriveItemsController < Api::V1::Flower::BaseController
  before_action :set_active_drive_item, only: :show
  before_action :set_deliverable_drive_item, only: :download

  def index
    drive_items = drive_item_query.list(parent_id: params[:parent_id], query: params[:query])
    record_flower_event!("flower.drive_items.index", metadata: { parent_id: params[:parent_id], query_present: params[:query].present? })

    render json: { items: drive_items.map { |drive_item| drive_item_json(drive_item) } }
  end

  def show
    record_flower_event!("flower.drive_items.show", target: @drive_item, metadata: { drive_item_id: @drive_item.id })
    render json: { item: drive_item_json(@drive_item, include_deleted_at: true) }
  end

  def resolve
    result = DriveItems::Resolve.new(organization: current_organization, items: params[:items]).call
    unless result.success?
      render_api_error(:validation_failed, result.error_message, status: result.status)
      return
    end

    record_flower_event!(
      "flower.drive_items.resolve",
      metadata: {
        requested_count: Array(params[:items]).size,
        statuses: result.items.group_by { |item| item[:status] }.transform_values(&:size)
      }
    )
    render json: { items: result.items }
  end

  def download
    result = DriveItems::DeliveryService.new(
      drive_item: @drive_item,
      current_user: current_user,
      request: request,
      action: :download,
      client_type: "flower"
    ).call

    unless result.success?
      record_flower_event!(
        "flower.drive_item.download_denied",
        target: @drive_item,
        outcome: "denied",
        metadata: download_metadata(@drive_item).merge(status: result.status, reason: result.error_message)
      )
      render_api_error(error_code_for_status(result.status), result.error_message, status: result.status)
      return
    end

    record_flower_event!("flower.drive_item.download_started", target: @drive_item, metadata: download_metadata(@drive_item))
    result.headers.each { |key, value| response.headers[key] = value }
    head result.status
  end

  private

  def set_active_drive_item
    @drive_item = drive_item_query.find_active(params[:id])
    return if @drive_item.present?

    render_flower_not_found
  end

  def set_deliverable_drive_item
    @drive_item = drive_item_query.find_deliverable(params[:id])
    if @drive_item.blank?
      record_flower_event!(
        "flower.drive_item.download_denied",
        outcome: "denied",
        metadata: { drive_item_id: params[:id], reason: "not_found" }
      )
      render_flower_not_found
    end
  end

  def drive_item_json(drive_item, include_deleted_at: false)
    data = {
      id: drive_item.id.to_s,
      parent_id: drive_item.parent_id&.to_s,
      parent_name: drive_item.parent&.name,
      name: drive_item.name,
      extension: drive_item.directory? ? nil : drive_item.extension,
      display_name: drive_item.filename,
      item_type: drive_item.item_type,
      content_type: drive_item.directory? ? nil : drive_item.content_type,
      file_size: drive_item.directory? ? nil : drive_item.file_size,
      file_hash: drive_item.directory? ? nil : drive_item.file_hash,
      owner_user_id: drive_item.owner_user_id,
      owner_display_name: drive_item.owner_user&.safe_display_name,
      created_at: drive_item.created_at,
      updated_at: drive_item.updated_at
    }
    data[:deleted_at] = drive_item.deleted_at if include_deleted_at
    data
  end

  def record_flower_event!(action, target: nil, outcome: "success", metadata: {})
    record_audit_event!(
      action: action,
      target: target,
      organization: current_organization,
      outcome: outcome,
      metadata: flower_metadata(metadata)
    )
  end

  def download_metadata(drive_item)
    {
      drive_item_id: drive_item.id,
      file_hash: drive_item.file_hash,
      file_size: drive_item.file_size
    }
  end

  def error_code_for_status(status)
    case Rack::Utils.status_code(status)
    when 401 then :unauthorized
    when 403 then :forbidden
    when 404 then :not_found
    when 413 then :payload_too_large
    when 422 then :validation_failed
    when 500..599 then :internal_error
    else :validation_failed
    end
  end
end
