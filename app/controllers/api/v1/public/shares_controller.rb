require "digest"

class Api::V1::Public::SharesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :set_no_store_headers
  before_action :rate_limit_public_request!
  before_action :set_external_share
  before_action :require_unlocked!, except: %i[show unlock]

  def show
    if @external_share.password_required? && !unlocked?
      render json: { password_required: true }
      return
    end

    record_external_access!("external_share.opened", outcome: "success")
    render json: share_json(items: item_scope.all_visible_items)
  end

  def unlock
    rate_limit_password_request!
    result = ExternalShares::PasswordUnlockService.new(
      external_share: @external_share,
      password: params[:password]
    ).call

    unless result.success?
      record_external_access!("external_share.password_failed", outcome: "denied", metadata: { reason: result.error_code })
      render_unlock_error(result)
      return
    end

    write_unlock_cookie!
    render json: { unlocked: true }
  end

  def items
    render json: { items: item_scope.visible_items(parent_id: params[:parent_id]).map { |item| public_item_json(item) } }
  end

  def item
    drive_item = item_scope.find_item(params[:drive_item_id])
    return render_public_not_found if drive_item.blank?

    render json: { item: public_item_json(drive_item) }
  end

  def download
    rate_limit_download_request!
    drive_item = item_scope.find_item(params[:drive_item_id])
    policy = ExternalShares::AccessPolicy.new(external_share: @external_share)
    return render_public_not_found unless policy.can_download?(drive_item)

    result = DriveItems::DeliveryService.new(
      drive_item: drive_item,
      current_user: nil,
      request: request,
      action: :download,
      record_audit: false,
      client_type: "external_share"
    ).call
    return render_public_not_found unless result.success?

    record_external_access!("external_share.file_downloaded", drive_item: drive_item, outcome: "success")
    result.headers.each { |key, value| response.headers[key] = value }
    response.headers["Cache-Control"] = "private, no-store"
    head result.status
  end

  def preview
    drive_item = item_scope.find_item(params[:drive_item_id])
    policy = ExternalShares::AccessPolicy.new(external_share: @external_share)
    return render_public_not_found unless policy.can_preview?(drive_item)

    result = DriveItems::DeliveryService.new(
      drive_item: drive_item,
      current_user: nil,
      request: request,
      action: :preview,
      record_audit: false,
      client_type: "external_share"
    ).call
    return render_public_not_found unless result.success?

    record_external_access!("external_share.file_previewed", drive_item: drive_item, outcome: "success")
    result.headers.each { |key, value| response.headers[key] = value }
    response.headers["Content-Security-Policy"] = "default-src 'none'; img-src 'self' data:; media-src 'self'; frame-ancestors 'none'"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "private, no-store"
    head result.status
  end

  def bulk_download
    rate_limit_download_request!
    policy = ExternalShares::AccessPolicy.new(external_share: @external_share)
    return render_public_not_found unless policy.can_bulk_download?

    result = DriveItems::BulkDownloadService.new(
      organization: @external_share.organization,
      drive_items: item_scope.visible_items.to_a
    ).call
    return render_public_not_found unless result.success?

    record_external_access!("external_share.bulk_downloaded", outcome: "success", metadata: { target_count: result.drive_items.size })
    send_zip_file(result)
  rescue StandardError => error
    result&.cleanup!
    Rails.logger.error("[public.external_shares.bulk_download] failed request_id=#{request.request_id} error=#{error.class}: #{error.message}")
    render_public_not_found unless performed?
  end

  private

  def set_external_share
    @external_share = ExternalShares::TokenResolver.new(raw_token: params[:token], include_inactive: action_name == "unlock").call
    render_public_not_found if @external_share.blank?
  end

  def item_scope
    @item_scope ||= ExternalShares::ItemScope.new(external_share: @external_share)
  end

  def require_unlocked!
    return unless @external_share.password_required?
    return if unlocked?

    render json: { password_required: true }, status: :unauthorized
  end

  def unlocked?
    cookies.signed[unlock_cookie_name] == @external_share.id
  end

  def write_unlock_cookie!
    expires_at = [ @external_share.expires_at, 12.hours.from_now ].compact.min
    cookies.signed[unlock_cookie_name] = {
      value: @external_share.id,
      expires: expires_at,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end

  def unlock_cookie_name
    "external_share_unlock_#{@external_share.id}"
  end

  def share_json(items:)
    {
      id: @external_share.id,
      name: @external_share.name,
      expires_at: @external_share.expires_at,
      allow_download: @external_share.allow_download,
      allow_bulk_download: @external_share.allow_bulk_download,
      password_required: @external_share.password_required?,
      items: items.map { |item| public_item_json(item) }
    }
  end

  def public_item_json(drive_item)
    {
      id: drive_item.id,
      parent_id: shared_parent_id(drive_item),
      name: drive_item.filename,
      item_type: drive_item.item_type,
      extension: drive_item.extension,
      content_type: drive_item.content_type,
      file_size: drive_item.file_size
    }
  end

  def shared_parent_id(drive_item)
    return nil if @external_share.external_share_items.exists?(drive_item_id: drive_item.id)
    return drive_item.parent_id if item_scope.include?(drive_item.parent)

    nil
  end

  def set_no_store_headers
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["X-Content-Type-Options"] = "nosniff"
  end

  def rate_limit_public_request!
    reject_rate_limited!(
      Security::RateLimiter.new(
        namespace: "external-share-public",
        key: "#{request.remote_ip}:#{params[:token].to_s.length}:#{Digest::SHA256.hexdigest(params[:token].to_s)}",
        limit: 120,
        period: 1.hour
      ).call
    )
  end

  def rate_limit_password_request!
    reject_rate_limited!(
      Security::RateLimiter.new(
        namespace: "external-share-password",
        key: "#{request.remote_ip}:#{@external_share.id}",
        limit: 10,
        period: 15.minutes
      ).call
    )
  end

  def rate_limit_download_request!
    reject_rate_limited!(
      Security::RateLimiter.new(
        namespace: "external-share-download",
        key: "#{request.remote_ip}:#{@external_share.id}",
        limit: 60,
        period: 1.hour
      ).call
    )
  end

  def reject_rate_limited!(result)
    return if result.allowed?

    response.headers["Retry-After"] = result.retry_after.to_s
    render_public_not_found(status: :too_many_requests)
  end

  def render_public_not_found(status: :not_found)
    render json: { error: { code: "not_found", message: "この共有リンクは利用できません" } }, status: status
  end

  def render_unlock_error(result)
    render json: {
      error: {
        code: result.error_code.to_s,
        message: result.error_message
      }
    }, status: result.status
  end

  def record_external_access!(action, drive_item: nil, outcome: "success", metadata: {})
    AuditEvents::Recorder.record!(
      action: action,
      organization: @external_share.organization,
      target: @external_share,
      outcome: outcome,
      metadata: {
        external_share_id: @external_share.id,
        drive_item_id: drive_item&.id
      }.merge(metadata),
      request: request
    )
  end

  def send_zip_file(result)
    response.headers["Content-Type"] = DriveItems::BulkDownloadService::ZIP_CONTENT_TYPE
    response.headers["Content-Disposition"] =
      ActionDispatch::Http::ContentDisposition.format(
        disposition: "attachment",
        filename: result.filename
      )
    response.headers["Content-Length"] = result.zip_size.to_s
    self.response_body = Api::V1::DriveItemsController::TemporaryFileBody.new(result)
  end
end
