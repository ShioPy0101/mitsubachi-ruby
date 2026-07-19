class Api::V1::Flower::BaseController < ApplicationController
  skip_forgery_protection
  before_action :authenticate_flower_token!

  attr_reader :current_flower_token

  private

  def current_user
    @current_user
  end

  def current_organization
    @current_organization
  end

  def current_client_type
    "flower"
  end

  def current_scopes
    @current_scopes || []
  end

  def required_flower_scopes
    [ "flower:read" ]
  end

  def authenticate_flower_token!
    result = Flower::Tokens::Authenticate.new(
      raw_token: bearer_token,
      required_scopes: required_flower_scopes
    ).call

    unless result.success?
      render_flower_error(result.error_code, result.message, status: result.status)
      return
    end

    @current_flower_token = result.token
    @current_user = result.user
    @current_organization = result.organization
    @current_scopes = result.scopes
  end

  def bearer_token
    authorization = request.authorization.to_s
    return unless authorization.start_with?("Bearer ")

    authorization.delete_prefix("Bearer ").strip.presence
  end

  def flower_metadata(metadata = {})
    { client_type: "flower" }.merge(metadata)
  end

  def render_flower_not_found
    render_flower_error("not_found", "Drive item was not found.", status: :not_found)
  end

  def drive_item_query
    @drive_item_query ||= DriveItems::Query.new(organization: current_organization)
  end

  def render_flower_error(code, message, status:, details: {})
    response.headers["X-Request-Id"] = request.request_id
    render json: {
      error: {
        code: code,
        message: message,
        request_id: request.request_id
      }.merge(details.present? ? { details: details } : {})
    }, status: status
  end
end
