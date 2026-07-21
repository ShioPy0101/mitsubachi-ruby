class Api::V1::Admin::OrganizationsController < Api::V1::Admin::BaseController
  SORT_COLUMNS = {
    "created_at" => :created_at,
    "name" => :name
  }.freeze

  def index
    scope = scoped_organizations
    scope = scope.where("organizations.name ILIKE ?", "%#{sanitize_sql_like(params[:q])}%") if params[:q].present?
    scope = scope.order(sort_column => sort_direction, id: :asc)

    records, meta = paginate(scope)
    render json: {
      data: records.map { |organization| organization_json(organization) },
      meta: meta
    }
  end

  def show
    organization = scoped_organizations.find_by(id: params[:id])
    return render_not_found if organization.nil?

    render json: { data: organization_json(organization) }
  end

  def create
    return render_error(:forbidden, "この操作を実行する権限がありません", :forbidden) unless system_admin?

    organization = Organization.new(organization_params)
    if organization.save
      audit_admin_action!(
        action: "organization.create",
        target: organization,
        organization: organization,
        changes: { name: [ nil, organization.name ] }
      )
      render json: { data: organization_json(organization) }, status: :created
    else
      render json: { errors: organization.errors.full_messages }, status: :unprocessable_content
    end
  end

  def update
    organization = scoped_organizations.find_by(id: params[:id])
    return render_not_found if organization.nil?

    before = organization.slice("name")
    if organization.update(organization_params)
      audit_admin_action!(
        action: "organization.update",
        target: organization,
        organization: organization,
        changes: changed_values(before, organization.slice("name"))
      )
      render json: { data: organization_json(organization) }
    else
      render_validation_error(organization)
    end
  end

  private

  def organization_params
    params.require(:organization).permit(:name)
  end

  def sort_column
    SORT_COLUMNS.fetch(params[:sort].to_s, :created_at)
  end

  def organization_json(organization)
    drive_items = organization.drive_items
    {
      id: organization.id,
      name: organization.name,
      users_count: organization.users.count,
      drive_items_count: drive_items.count,
      storage_bytes: drive_items.file.sum(:file_size),
      created_at: organization.created_at,
      updated_at: organization.updated_at
    }
  end

  def sanitize_sql_like(value)
    ActiveRecord::Base.sanitize_sql_like(value.to_s)
  end

  def changed_values(before, after)
    before.each_with_object({}) do |(key, old_value), changes|
      new_value = after[key]
      changes[key] = [ old_value, new_value ] if old_value != new_value
    end
  end
end
