class Api::HealthController < ApplicationController
  skip_forgery_protection

  def live
    render json: { status: "ok" }
  end

  def ready
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "ok" }
  rescue ActiveRecord::ActiveRecordError
    render json: { status: "unavailable" }, status: :service_unavailable
  end
end
