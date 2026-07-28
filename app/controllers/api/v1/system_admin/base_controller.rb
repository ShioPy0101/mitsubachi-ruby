class Api::V1::SystemAdmin::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_system_admin!

  private

  MAX_PER_PAGE = 100

  def require_system_admin!
    return if current_user.system_admin?

    render json: { error: { code: "forbidden", message: "この操作を実行する権限がありません" } }, status: :forbidden
  end

  def render_collection(scope, serializer)
    page = [ params[:page].to_i, 1 ].max
    per_page = [ [ params[:per_page].presence.to_i, 20 ].max, MAX_PER_PAGE ].min
    total_count = scope.count
    records = scope.offset((page - 1) * per_page).limit(per_page)
    render json: { data: records.map { |record| serializer.call(record) }, meta: {
      current_page: page, per_page: per_page, total_pages: [ (total_count.to_f / per_page).ceil, 1 ].max,
      total_count: total_count
    } }
  end

  def render_not_found
    render json: { error: { code: "not_found", message: "対象が見つかりません" } }, status: :not_found
  end
end
