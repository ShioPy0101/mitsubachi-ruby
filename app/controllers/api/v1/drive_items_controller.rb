require "fileutils"
require "securerandom"

class Api::V1::DriveItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_active_drive_item, only: %i[show update destroy]
  before_action :set_deleted_drive_item, only: %i[restore]
  before_action :set_deliverable_drive_item, only: %i[preview download stream]

  def index
    @drive_items =
      current_user.organization
                  .drive_items
                  .active
                  .where(parent_id: params[:parent_id])
                  .order(item_type: :desc, name: :asc)

    render json: @drive_items
  end

  def create
    name = params[:name]
    parent_id = normalized_parent_id
    item_type = params[:item_type]

    unless valid_item_type?(item_type)
      render json: { error: "ファイルタイプは file または directory のいずれかである必要があります" }, status: :unprocessable_entity
      return
    end

    if file_item_without_upload?(item_type)
      render json: { error: "ファイルが指定されていません" }, status: :unprocessable_entity
      return
    end

    if directory_item_with_upload?(item_type)
      render json: { error: "ディレクトリ作成時にファイルは指定できません" }, status: :unprocessable_entity
      return
    end

    return unless validate_parent_id(parent_id, not_found_message: "指定された親フォルダが見つかりません", invalid_message: "親にはディレクトリを指定してください")

    extension = item_type == "file" ? get_extension_from_filename(params[:file].original_filename) : nil

    if duplicate_active_item?(parent_id:, name:, extension:)
      render json: { error: "同じ名前のファイルまたはフォルダが既に存在します" }, status: :unprocessable_entity
      return
    end

    @drive_item = current_user.organization.drive_items.new(
      name: name,
      item_type: item_type,
      parent_id: parent_id,
      owner_user: current_user
    )

    if item_type == "file"
      uploaded_file = params[:file]
      if upload_too_large?(uploaded_file)
        render json: { error: "ファイルサイズが上限を超えています" }, status: :content_too_large
        return
      end

      generated_storage_key = build_storage_key(extension)
      file_saved = false
      saved = false

      begin
        file_saved = true
        stored_file = save_uploaded_file(uploaded_file, generated_storage_key)

        @drive_item.storage_key = stored_file.storage_key
        @drive_item.extension = extension
        @drive_item.file_hash = stored_file.sha256
        @drive_item.file_size = stored_file.byte_size
        @drive_item.content_type = stored_file.content_type

        saved = @drive_item.save
        if saved
          render json: @drive_item, status: :created
        else
          render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.error("[drive_items.create] failed to save drive_item error=#{error.class}: #{error.message}")
        render json: { error: "ファイルを保存できませんでした" }, status: :unprocessable_entity
      rescue DriveItems::StoredFileInspector::UploadTooLargeError
        render json: { error: "ファイルサイズが上限を超えています" }, status: :content_too_large
      ensure
        cleanup_uploaded_file!(generated_storage_key) if file_saved && !saved
      end
    else
      @drive_item.extension = nil
      @drive_item.storage_key = nil
      @drive_item.blob_path = nil
      @drive_item.file_hash = nil
      @drive_item.file_size = nil
      @drive_item.content_type = nil

      if @drive_item.save
        render json: @drive_item, status: :created
      else
        render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end

  def show
    render json: @drive_item
  end

  def update
    @drive_item.name = params[:name] if params[:name].present?

    if params.key?(:parent_id)
      new_parent_id = normalized_parent_id

      return unless validate_parent_id(new_parent_id, not_found_message: "指定された新しい親フォルダが見つかりません", invalid_message: "新しい親にはディレクトリを指定してください")

      @drive_item.parent_id = new_parent_id
    end

    if @drive_item.save
      render json: @drive_item
    else
      render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    if @drive_item.update(deleted_at: Time.current)
      render json: { message: "ファイルまたはフォルダをゴミ箱に移動しました" }
    else
      render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def trash
    @drive_items =
      current_user.organization
                  .drive_items
                  .deleted
                  .order(deleted_at: :desc)
    render json: @drive_items
  end

  def bulk_move
    new_parent_id = normalized_parent_id
    return unless validate_parent_id(new_parent_id, not_found_message: "指定された新しい親フォルダが見つかりません", invalid_message: "新しい親にはディレクトリを指定してください")

    update_drive_items!(active_drive_items_for_bulk) do |drive_item|
      drive_item.update!(parent_id: new_parent_id)
    end

    render json: { message: "ファイルまたはフォルダを移動しました" } unless performed?
  end

  def bulk_delete
    deleted_at = Time.current

    update_drive_items!(active_drive_items_for_bulk) do |drive_item|
      drive_item.update!(deleted_at: deleted_at)
    end

    render json: { message: "ファイルまたはフォルダをゴミ箱に移動しました" } unless performed?
  end

  def bulk_restore
    update_drive_items!(deleted_drive_items_for_bulk) do |drive_item|
      drive_item.update!(deleted_at: nil)
    end

    render json: { message: "ファイルまたはフォルダを復元しました" } unless performed?
  end

  def bulk_download
    result = DriveItems::BulkDownloadService.new(
      organization: current_user.organization,
      drive_item_ids: params[:drive_item_ids]
    ).call

    unless result.success?
      render json: { error: result.error_message }, status: result.status
      return
    end

    record_bulk_download_access!(result.drive_items)
    send_zip_file(result)
  rescue StandardError => error
    result&.cleanup!
    Rails.logger.error("[drive_items.bulk_download] failed to send zip error=#{error.class}: #{error.message}")
    return if performed?

    render json: { error: "ZIPファイルを送信できませんでした" }, status: :unprocessable_entity
  end

  def preview
    deliver_drive_item(:preview)
  end

  def download
    deliver_drive_item(:download)
  end

  def stream
    deliver_drive_item(:stream)
  end

  def restore
    if @drive_item.update(deleted_at: nil)
      render json: @drive_item
    else
      render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def set_active_drive_item
    @drive_item = current_user.organization.drive_items.active.find_by(id: params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def set_deleted_drive_item
    @drive_item = current_user.organization.drive_items.deleted.find_by(id: params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def set_deliverable_drive_item
    @drive_item = current_user.organization.drive_items.active.find_by(id: params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def get_extension_from_filename(filename)
    File.extname(filename).delete_prefix(".").downcase
  end

  def normalized_parent_id
    parent_id = params[:parent_id]
    parent_id.present? ? parent_id : nil
  end

  def valid_item_type?(item_type)
    item_type == "file" || item_type == "directory"
  end

  def file_item_without_upload?(item_type)
    item_type == "file" && params[:file].nil?
  end

  def directory_item_with_upload?(item_type)
    item_type == "directory" && params[:file].present?
  end

  def validate_parent_id(parent_id, not_found_message:, invalid_message:)
    return true if parent_id.blank?

    parent = current_user.organization.drive_items.active.find_by(id: parent_id)
    if parent.nil?
      render json: { error: not_found_message }, status: :not_found
      return false
    end

    unless parent.directory?
      render json: { error: invalid_message }, status: :unprocessable_entity
      return false
    end

    true
  end

  def duplicate_active_item?(parent_id:, name:, extension:)
    current_user
      .organization
      .drive_items
      .active
      .exists?(parent_id: parent_id, name: name, extension: extension)
  end

  def active_drive_items_for_bulk
    current_user.organization.drive_items.active.where(id: params[:drive_item_ids])
  end

  def deleted_drive_items_for_bulk
    current_user.organization.drive_items.deleted.where(id: params[:drive_item_ids])
  end

  def update_drive_items!(drive_items)
    ActiveRecord::Base.transaction do
      drive_items.find_each do |drive_item|
        yield drive_item
      end
    end
  rescue ActiveRecord::RecordInvalid => error
    render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error("[drive_items.bulk] failed error=#{error.class}: #{error.message}")
    render json: { error: "一括操作に失敗しました" }, status: :unprocessable_entity
  end

  def save_uploaded_file(uploaded_file, storage_key)
    DriveItems::StoredFileInspector.copy_upload!(
      uploaded_file: uploaded_file,
      storage_path: DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key)),
      filename: uploaded_file.original_filename,
      storage_key: storage_key
    )
  end

  def build_storage_key(extension)
    suffix = extension.present? ? ".#{extension}" : ""
    "#{SecureRandom.uuid}#{suffix}"
  end

  def cleanup_uploaded_file!(storage_key)
    safe_storage_key = storage_key.to_s
    return unless DriveItem.valid_storage_key?(safe_storage_key)

    FileUtils.rm_f(DriveItem.storage_root.join("drive_items", safe_storage_key))
  end

  def upload_too_large?(uploaded_file)
    uploaded_file.size.to_i > Rails.configuration.x.max_upload_size_bytes
  end

  def deliver_drive_item(action)
    result = DriveItems::DeliveryService.new(
      drive_item: @drive_item,
      current_user: current_user,
      request: request,
      action: action
    ).call

    unless result.success?
      render json: { error: result.error_message }, status: result.status
      return
    end

    result.headers.each do |key, value|
      response.headers[key] = value
    end

    head result.status
  end

  def render_not_found
    render json: { error: "指定されたファイルが見つかりません" }, status: :not_found
  end

  def record_bulk_download_access!(drive_items)
    now = Time.current

    drive_items.each do |drive_item|
      DriveItemAccessLog.create!(
        organization: current_user.organization,
        user: current_user,
        drive_item: drive_item,
        action: "bulk_download",
        occurred_at: now,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        request_id: request.request_id
      )
    end
  end

  def send_zip_file(result)
    response.headers["Content-Type"] = DriveItems::BulkDownloadService::ZIP_CONTENT_TYPE
    response.headers["Content-Disposition"] =
      ActionDispatch::Http::ContentDisposition.format(
        disposition: "attachment",
        filename: result.filename
      )
    response.headers["Content-Length"] = result.zip_size.to_s
    self.response_body = TemporaryFileBody.new(result)
  end

  class TemporaryFileBody
    def initialize(result)
      @result = result
    end

    def each
      @result.each_chunk { |chunk| yield chunk }
    end

    def close
      @result.cleanup!
    end
  end
end
