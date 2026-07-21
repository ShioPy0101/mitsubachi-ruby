class Api::V1::ExternalSharesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_external_share, only: %i[show update destroy regenerate_password]

  def index
    shares = manageable_external_shares.includes(:created_by_user).order(created_at: :desc)
    render json: shares.map { |share| external_share_json(share) }
  end

  def show
    render json: external_share_json(@external_share, include_items: true)
  end

  def create
    result = ExternalShares::CreateService.new(user: current_user, params: external_share_params.to_h.symbolize_keys).call
    unless result.success?
      render_api_error(error_code_for_status(result.status), result.error_message, status: result.status)
      return
    end

    record_external_share_event!("external_share.created", result.external_share, metadata: creation_metadata(result.external_share))
    response_body = external_share_json(result.external_share).merge(share_url: share_url(result.raw_token))
    response_body[:generated_password] = result.generated_password if result.generated_password.present?
    render json: response_body, status: :created
  end

  def update
    result = ExternalShares::UpdateService.new(external_share: @external_share, params: external_share_params.to_h.symbolize_keys).call
    unless result.success?
      render_api_error(error_code_for_status(result.status), result.error_message, status: result.status)
      return
    end

    record_external_share_event!("external_share.updated", @external_share, changes: result.changes, metadata: creation_metadata(@external_share))
    render json: external_share_json(@external_share)
  end

  def destroy
    ExternalShares::RevokeService.new(external_share: @external_share).call
    record_external_share_event!("external_share.revoked", @external_share, metadata: creation_metadata(@external_share))
    render json: external_share_json(@external_share)
  end

  def regenerate_password
    result = ExternalShares::PasswordRegenerationService.new(external_share: @external_share).call
    unless result.success?
      render_api_error(:validation_failed, result.error_message, status: :unprocessable_content)
      return
    end

    record_external_share_event!("external_share.password_regenerated", @external_share, metadata: creation_metadata(@external_share))
    render json: external_share_json(@external_share).merge(generated_password: result.generated_password)
  end

  private

  def set_external_share
    @external_share = manageable_external_shares.find_by(id: params[:id])
    render_not_found("外部公開が見つかりません") if @external_share.blank?
  end

  def manageable_external_shares
    return ExternalShare.all if current_user.system_admin?
    return current_user.organization.external_shares if current_user.organization_admin?

    current_user.created_external_shares
  end

  def external_share_params
    params.require(:external_share).permit(
      :name,
      :expires_at,
      :allow_download,
      :allow_bulk_download,
      :password_protected,
      :folder_share_mode,
      drive_item_ids: []
    )
  end

  def external_share_json(external_share, include_items: false)
    data = {
      id: external_share.id,
      name: external_share.name,
      expires_at: external_share.expires_at,
      revoked_at: external_share.revoked_at,
      folder_share_mode: external_share.folder_share_mode,
      allow_download: external_share.allow_download,
      allow_bulk_download: external_share.allow_bulk_download,
      password_required: external_share.password_required?,
      created_by_user_id: external_share.created_by_user_id,
      created_at: external_share.created_at,
      updated_at: external_share.updated_at
    }
    data[:items] = external_share.drive_items.order(:id).map { |item| drive_item_json(item) } if include_items
    data
  end

  def drive_item_json(drive_item)
    {
      id: drive_item.id,
      parent_id: drive_item.parent_id,
      name: drive_item.name,
      item_type: drive_item.item_type,
      extension: drive_item.extension,
      file_size: drive_item.file_size,
      content_type: drive_item.content_type
    }
  end

  def share_url(raw_token)
    "#{ENV.fetch('FRONTEND_URL', request.base_url)}/share/#{raw_token}"
  end

  def creation_metadata(external_share)
    {
      external_share_id: external_share.id,
      created_by_user_id: external_share.created_by_user_id,
      organization_id: external_share.organization_id,
      target_count: external_share.external_share_items.count,
      folder_share_mode: external_share.folder_share_mode,
      expires_at: external_share.expires_at,
      allow_download: external_share.allow_download,
      allow_bulk_download: external_share.allow_bulk_download
    }
  end

  def record_external_share_event!(action, external_share, changes: {}, metadata: {})
    record_audit_event!(
      action: action,
      target: external_share,
      organization: external_share.organization,
      changes: changes,
      metadata: metadata
    )
  end

  def error_code_for_status(status)
    case Rack::Utils.status_code(status)
    when 404 then :not_found
    when 422 then :validation_failed
    else :validation_failed
    end
  end
end
