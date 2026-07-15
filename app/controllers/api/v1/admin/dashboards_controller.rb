class Api::V1::Admin::DashboardsController < Api::V1::Admin::BaseController
  def show
    users = scoped_users
    drive_items = scoped_drive_items

    render json: {
      data: {
        organizations_count: scoped_organizations.count,
        users_count: users.count,
        active_users_count: users.active.count,
        drive_items_count: drive_items.count,
        files_count: drive_items.file.count,
        directories_count: drive_items.directory.count,
        total_storage_bytes: drive_items.file.sum(:file_size),
        recent_users: users.includes(:organization).order(created_at: :desc).limit(5).map { |user| user_json(user) },
        recent_drive_items: drive_items.includes(:organization, :owner_user).order(created_at: :desc).limit(5).map { |item| drive_item_json(item) }
      }
    }
  end

  private

  def user_json(user)
    {
      id: user.id,
      organization_id: user.organization_id,
      organization_name: user.organization.name,
      email: user.email,
      name: user.name,
      role: user.role,
      suspended: user.suspended?,
      created_at: user.created_at
    }
  end

  def drive_item_json(drive_item)
    {
      id: drive_item.id,
      organization_id: drive_item.organization_id,
      organization_name: drive_item.organization.name,
      owner_user_id: drive_item.owner_user_id,
      owner_email: drive_item.owner_user.email,
      name: drive_item.name,
      item_type: drive_item.item_type,
      content_type: drive_item.content_type,
      file_size: drive_item.file_size,
      deleted_at: drive_item.deleted_at,
      created_at: drive_item.created_at
    }
  end
end
