require "fileutils"
require "securerandom"

class DriveItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_drive_item, only: %i[show update destroy restore]
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
    parent_id = params[:parent_id]
    item_type = params[:item_type]

    if item_type != "file" && item_type != "directory"
      render json: { error: "ファイルタイプは file または directory のいずれかである必要があります" }, status: :unprocessable_entity
      return
    end

    if item_type == "file" && params[:file].nil?
      render json: { error: "ファイルが指定されていません" }, status: :unprocessable_entity
      return
    end

    if item_type == "directory" && params[:file].present?
      render json: { error: "ディレクトリ作成時にファイルは指定できません" }, status: :unprocessable_entity
      return
    end

    if parent_id.present?
      parent = current_user.organization.drive_items.active.find_by(id: parent_id)

      if parent.nil?
        render json: { error: "指定された親フォルダが見つかりません" }, status: :not_found
        return
      end

      unless parent.directory?
        render json: { error: "親にはディレクトリを指定してください" }, status: :unprocessable_entity
        return
      end
    end

    if current_user.organization.drive_items.exists?(parent_id: parent_id, name: name, extension: item_type == "file" ? get_extension_from_filename(params[:file].original_filename) : nil)
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
      extension = get_extension_from_filename(uploaded_file.original_filename)
      generated_storage_key = build_storage_key(extension)
      stored_file = save_uploaded_file(uploaded_file, generated_storage_key)

      @drive_item.storage_key = stored_file.storage_key
      @drive_item.extension = extension
      @drive_item.file_hash = stored_file.sha256
      @drive_item.file_size = stored_file.byte_size
      @drive_item.content_type = stored_file.content_type

      if @drive_item.save
        render json: @drive_item, status: :created
      else
        cleanup_uploaded_file!(generated_storage_key)
        render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
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
    @drive_item = current_user.organization.drive_items.active.find_by(id: params[:id])

    if @drive_item.nil?
      render json: { error: "指定されたファイルまたはフォルダが見つかりません" }, status: :not_found
    else
      render json: @drive_item
    end
  end

  def update
    @drive_item = current_user.organization.drive_items.active.find_by(id: params[:id])

    if @drive_item.nil?
      render json: { error: "指定されたファイルまたはフォルダが見つかりません" }, status: :not_found
      return
    end

    @drive_item.name = params[:name] if params[:name].present?

    if params[:parent_id].present?
      new_parent = current_user.organization.drive_items.active.find_by(id: params[:parent_id])

      if new_parent.nil?
        render json: { error: "指定された新しい親フォルダが見つかりません" }, status: :not_found
        return
      end

      unless new_parent.directory?
        render json: { error: "新しい親にはディレクトリを指定してください" }, status: :unprocessable_entity
        return
      end

      @drive_item.parent_id = params[:parent_id]
    end

    if @drive_item.save
      render json: @drive_item
    else
      render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @drive_item = current_user.organization.drive_items.active.find_by(id: params[:id])

    if @drive_item.nil?
      render json: { error: "指定されたファイルまたはフォルダが見つかりません" }, status: :not_found
      return
    end

    @drive_item.update(deleted_at: Time.current)
    render json: { message: "ファイルまたはフォルダをゴミ箱に移動しました" }
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
    new_parent = current_user.organization.drive_items.active.find_by(id: params[:parent_id])

    if new_parent.nil?
      render json: { error: "指定された新しい親フォルダが見つかりません" }, status: :not_found
      return
    end

    unless new_parent.directory?
      render json: { error: "新しい親にはディレクトリを指定してください" }, status: :unprocessable_entity
      return
    end

    @drive_items = current_user.organization.drive_items.active.where(id: params[:drive_item_ids])
    @drive_items.update_all(parent_id: params[:parent_id])

    render json: { message: "ファイルまたはフォルダを移動しました" }
  end

  def bulk_delete
    @drive_items = current_user.organization.drive_items.active.where(id: params[:drive_item_ids])
    @drive_items.update_all(deleted_at: Time.current)

    render json: { message: "ファイルまたはフォルダをゴミ箱に移動しました" }
  end

  def bulk_restore
    @drive_items = current_user.organization.drive_items.deleted.where(id: params[:drive_item_ids])
    @drive_items.update_all(deleted_at: nil)

    render json: { message: "ファイルまたはフォルダを復元しました" }
  end

  def bulk_download
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
  end

  private

  def set_drive_item
    @drive_item =
      current_user.organization
                  .drive_items
                  .find(params[:id])
  end

  def set_deliverable_drive_item
    @drive_item = current_user.organization.drive_items.active.find_by(id: params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def get_extension_from_filename(filename)
    File.extname(filename).delete_prefix(".").downcase
  end

  def save_uploaded_file(uploaded_file, storage_key)
    DriveItems::StoredFileInspector.copy_upload!(
      uploaded_file: uploaded_file,
      storage_path: Rails.root.join("storage", DriveItem.storage_relative_path_for(storage_key)),
      filename: uploaded_file.original_filename,
      storage_key: storage_key
    )
  end

  def build_storage_key(extension)
    suffix = extension.present? ? ".#{extension}" : ""
    "#{SecureRandom.uuid}#{suffix}"
  end

  def cleanup_uploaded_file!(storage_key)
    return unless DriveItem.valid_storage_key?(storage_key)

    FileUtils.rm_f(Rails.root.join("storage", DriveItem.storage_relative_path_for(storage_key)))
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

    head :ok
  end

  def render_not_found
    render json: { error: "指定されたファイルが見つかりません" }, status: :not_found
  end
end
