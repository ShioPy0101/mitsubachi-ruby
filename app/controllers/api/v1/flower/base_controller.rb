class Api::V1::Flower::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_flower_client_session!

  private

  def flower_metadata(metadata = {})
    { client_type: "flower" }.merge(metadata)
  end

  def render_flower_not_found
    render_api_error(:not_found, "指定されたファイルが見つかりません", status: :not_found)
  end

  def drive_item_query
    @drive_item_query ||= DriveItems::Query.new(organization: current_organization)
  end

  def require_flower_client_session!
    return if performed?
    return if current_client_type == "flower"

    render_api_error(:unauthorized, "flowerでのログインが必要です。", status: :unauthorized)
  end
end
