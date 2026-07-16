class Api::V1::Admin::DriveItemsController < Api::V1::Admin::BaseController
  SORT_COLUMNS = {
    "created_at" => :created_at,
    "size" => :file_size,
    "name" => :name
  }.freeze

  def index
    scope = scoped_drive_items.includes(:organization, :owner_user)
    scope = apply_filters(scope)
    scope = scope.order(sort_column => sort_direction, id: :asc)

    render_collection(scope, method(:drive_item_json))
  end

  def show
    drive_item = find_scoped_drive_item
    return render_not_found if drive_item.nil?

    render json: { data: drive_item_json(drive_item) }
  end

  def destroy
    drive_item = find_scoped_drive_item
    return render_not_found if drive_item.nil?

    before = drive_item.deleted_at
    if drive_item.update(deleted_at: Time.current)
      audit_admin_action!(
        action: "drive_item.delete",
        target: drive_item,
        organization: drive_item.organization,
        changes: { deleted_at: [ before, drive_item.deleted_at ] }
      )
      render json: { data: drive_item_json(drive_item) }
    else
      render_validation_error(drive_item)
    end
  end

  def preview
    deliver_admin_drive_item(:preview)
  end

  def download
    deliver_admin_drive_item(:download)
  end

  def stream
    deliver_admin_drive_item(:stream)
  end

  def purge
    return render_error(:forbidden, "この操作を実行する権限がありません", :forbidden) unless system_admin?

    drive_item = find_scoped_drive_item
    return render_not_found if drive_item.nil?

    result = Admin::DriveItems::PurgeService.new(drive_item: drive_item).call
    unless result.success?
      render json: { error: result.message }, status: result.status
      return
    end

    audit_admin_action!(
      action: "drive_item.purge",
      target: drive_item,
      organization: drive_item.organization,
      changes: { purged_at: [ nil, Time.current ] }
    )
    render json: { message: result.message }
  end

  def restore
    drive_item = find_scoped_drive_item
    return render_not_found if drive_item.nil?

    before = drive_item.deleted_at
    if drive_item.update(deleted_at: nil)
      audit_admin_action!(
        action: "drive_item.restore",
        target: drive_item,
        organization: drive_item.organization,
        changes: { deleted_at: [ before, nil ] }
      )
      render json: { data: drive_item_json(drive_item) }
    else
      render_validation_error(drive_item)
    end
  end

  private

  def find_scoped_drive_item
    scoped_drive_items.includes(:organization, :owner_user).find_by(id: params[:id])
  end

  def find_deliverable_drive_item
    scoped_drive_items.active.includes(:organization, :owner_user).find_by(id: params[:id])
  end

  def deliver_admin_drive_item(action)
    drive_item = find_deliverable_drive_item
    return render_not_found if drive_item.nil?

    result = DriveItems::DeliveryService.new(
      drive_item: drive_item,
      current_user: current_user,
      request: request,
      action: action,
      audit_organization: drive_item.organization
    ).call

    unless result.success?
      render json: { error: result.error_message }, status: result.status
      return
    end

    audit_admin_action!(
      action: "drive_item.#{action}",
      target: drive_item,
      organization: drive_item.organization
    )
    result.headers.each do |key, value|
      response.headers[key] = value
    end
    head result.status
  end

  def apply_filters(scope)
    if params[:q].present?
      query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s)}%"
      scope = scope.where("drive_items.name ILIKE ?", query)
    end

    scope = scope.where(organization_id: params[:organization_id]) if system_admin? && params[:organization_id].present?
    scope = scope.where(owner_user_id: params[:user_id]) if params[:user_id].present?
    scope = scope.where(item_type: params[:item_type]) if params[:item_type].present? && DriveItem.item_types.key?(params[:item_type])
    scope = scope.where(content_type: params[:content_type]) if params[:content_type].present?
    scope = apply_deleted_filter(scope)
    scope
  end

  def apply_deleted_filter(scope)
    case params[:deleted].to_s
    when "true", "deleted"
      scope.deleted
    when "false", "active"
      scope.active
    else
      scope
    end
  end

  def sort_column
    SORT_COLUMNS.fetch(params[:sort].to_s, :created_at)
  end

  def drive_item_json(drive_item)
    {
      id: drive_item.id,
      organization_id: drive_item.organization_id,
      organization_name: drive_item.organization.name,
      owner_user_id: drive_item.owner_user_id,
      owner_email: drive_item.owner_user.email,
      parent_id: drive_item.parent_id,
      name: drive_item.name,
      item_type: drive_item.item_type,
      extension: drive_item.extension,
      content_type: drive_item.content_type,
      file_size: drive_item.file_size,
      upload_ip_address: drive_item.upload_ip_address,
      uploaded_at: drive_item.created_at,
      deleted_at: drive_item.deleted_at,
      created_at: drive_item.created_at,
      updated_at: drive_item.updated_at
    }
  end
end
