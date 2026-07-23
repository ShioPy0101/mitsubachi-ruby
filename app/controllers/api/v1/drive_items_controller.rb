require "digest"
require "fileutils"
require "securerandom"
require "set"

class Api::V1::DriveItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_active_drive_item, only: %i[show update move destroy]
  before_action :set_deleted_drive_item, only: %i[restore restore_preview purge]
  before_action :set_deliverable_drive_item, only: %i[preview download stream]

  def index
    @drive_items =
      drive_item_query.list(parent_id: params[:parent_id])

    render json: @drive_items.map { |drive_item| drive_item_json(drive_item) }
  end

  def search
    query = params[:q].to_s.strip
    scope = params[:scope].presence || "current"
    page = [ params[:page].to_i, 1 ].max
    per_page = params[:per_page].present? ? params[:per_page].to_i.clamp(1, 50) : 20

    items = drive_item_query.active.includes(:owner_user, :parent)
    items = items.where(parent_id: params[:parent_id]) if scope == "current"
    items = apply_drive_item_search(items, query) if query.present?

    total_count = items.count
    drive_items = items.order(item_type: :desc, name: :asc).offset((page - 1) * per_page).limit(per_page)

    render json: {
      data: drive_items.map { |drive_item| drive_item_json(drive_item) },
      meta: {
        current_page: page,
        per_page: per_page,
        total_pages: (total_count.to_f / per_page).ceil,
        total_count: total_count
      }
    }
  end

  def create
    name = params[:name]
    parent_id = normalized_parent_id
    item_type = params[:item_type]

    unless valid_item_type?(item_type)
      render_api_error(:validation_failed, "ファイルタイプは file または directory のいずれかである必要があります", status: :unprocessable_content)
      return
    end

    if file_item_without_upload?(item_type)
      render_api_error(:invalid_file, "ファイルが指定されていません", status: :unprocessable_content)
      return
    end

    if directory_item_with_upload?(item_type)
      render_api_error(:invalid_file, "ディレクトリ作成時にファイルは指定できません", status: :unprocessable_content)
      return
    end

    return unless validate_parent_id(parent_id, not_found_message: "指定された親フォルダが見つかりません", invalid_message: "親にはディレクトリを指定してください")

    extension = item_type == "file" ? get_extension_from_filename(params[:file].original_filename) : nil

    @drive_item = current_user.organization.drive_items.new(
      name: name,
      item_type: item_type,
      parent_id: parent_id,
      owner_user: current_user,
      upload_ip_address: request.remote_ip
    )

    if item_type == "file"
      uploaded_file = params[:file]
      if upload_too_large?(uploaded_file)
        render_api_error(:payload_too_large, "ファイルサイズが上限を超えています", status: :content_too_large)
        return
      end

      if duplicate_active_item?(parent_id:, name:, extension:)
        render_name_conflict(name, parent_id:, extension:)
        return
      end

      upload_hash = digest_uploaded_file(uploaded_file)
      replace_target = nil
      if replace_trashed_drive_item_id.present?
        replace_target = replace_target_for_upload(upload_hash)
        return if performed?
      end

      if (active_duplicate = active_content_duplicate_item(upload_hash))
        render_active_content_duplicate(active_duplicate)
        return
      end

      if replace_target.present?
        replace_trashed_upload!(uploaded_file:, upload_hash:, extension:, replace_target:)
        return
      end

      trash_duplicate = trash_content_duplicate_item(upload_hash)
      if trash_duplicate.present? && !allow_trash_duplicate?
        render_trash_content_duplicate(trash_duplicate)
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
          record_drive_item_event!("drive_item.create", @drive_item)
          render json: drive_item_json(@drive_item), status: :created
        else
          render_validation_failed(@drive_item)
        end
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.error("[drive_items.create] failed to save drive_item error=#{error.class}: #{error.message}")
        render_api_error(:validation_failed, "ファイルを保存できませんでした", status: :unprocessable_content)
      rescue DriveItems::StoredFileInspector::UploadTooLargeError
        render_api_error(:payload_too_large, "ファイルサイズが上限を超えています", status: :content_too_large)
      ensure
        cleanup_uploaded_file!(generated_storage_key) if file_saved && !saved
      end
    else
      if duplicate_active_item?(parent_id:, name:, extension:)
        render_name_conflict(name, parent_id:, extension:)
        return
      end

      @drive_item.extension = nil
      @drive_item.storage_key = nil
      @drive_item.blob_path = nil
      @drive_item.file_hash = nil
      @drive_item.file_size = nil
      @drive_item.content_type = nil

      if @drive_item.save
        record_drive_item_event!("drive_item.create", @drive_item)
        render json: drive_item_json(@drive_item), status: :created
      else
        render_validation_failed(@drive_item)
      end
    end
  end

  def show
    render json: drive_item_json(@drive_item, include_breadcrumbs: true)
  end

  def update
    before = @drive_item.slice("name", "parent_id")
    @drive_item.name = params[:name] if params[:name].present?

    if params.key?(:parent_id)
      new_parent_id = normalized_parent_id

      return unless validate_parent_id(new_parent_id, not_found_message: "指定された新しい親フォルダが見つかりません", invalid_message: "新しい親にはディレクトリを指定してください")

      @drive_item.parent_id = new_parent_id
    end

    if duplicate_active_item?(parent_id: @drive_item.parent_id, name: @drive_item.name, extension: @drive_item.extension, excluding_id: @drive_item.id)
      render_name_conflict(@drive_item.name, parent_id: @drive_item.parent_id, extension: @drive_item.extension)
      return
    end

    if @drive_item.save
      record_drive_item_event!(
        "drive_item.update",
        @drive_item,
        changes: changed_values(before, @drive_item.slice("name", "parent_id"))
      )
      render json: drive_item_json(@drive_item)
    else
      render_validation_failed(@drive_item)
    end
  end

  def move
    before = @drive_item.slice("parent_id")
    return unless assign_parent_for_move!(@drive_item, normalized_parent_id)

    if duplicate_active_item?(parent_id: @drive_item.parent_id, name: @drive_item.name, extension: @drive_item.extension, excluding_id: @drive_item.id)
      render_duplicate_name(@drive_item.name, parent_id: @drive_item.parent_id, extension: @drive_item.extension)
      return
    end

    if @drive_item.save
      record_drive_item_event!(
        "drive_item.move",
        @drive_item,
        changes: changed_values(before, @drive_item.slice("parent_id"))
      )
      render json: { data: drive_item_json(@drive_item), request_id: request.request_id }
    else
      render_validation_failed(@drive_item)
    end
  end

  def destroy
    before = @drive_item.deleted_at
    result = DriveItems::TrashService.new(drive_items: [ @drive_item ]).call
    unless result.success?
      render_api_error(error_code_for_status(result.status), result.message, status: result.status)
      return
    end

    @drive_item.reload
    record_drive_item_event!("drive_item.delete", @drive_item, changes: { deleted_at: [ before, @drive_item.deleted_at ] })
    render json: { message: result.message }
  end

  def trash
    @drive_items =
      current_user.organization
                  .drive_items
                  .includes(:owner_user, :parent)
                  .deleted
                  .order(deleted_at: :desc)
    render json: @drive_items.map { |drive_item| drive_item_json(drive_item) }
  end

  def bulk_move
    new_parent_id = normalized_parent_id
    return unless validate_parent_id(new_parent_id, not_found_message: "指定された新しい親フォルダが見つかりません", invalid_message: "新しい親にはディレクトリを指定してください")

    drive_items = active_drive_items_for_bulk.to_a
    drive_items.each do |drive_item|
      return if invalid_move_target?(drive_item, new_parent_id)

      if duplicate_active_item?(parent_id: new_parent_id, name: drive_item.name, extension: drive_item.extension, excluding_id: drive_item.id)
        render_duplicate_name(drive_item.name, parent_id: new_parent_id, extension: drive_item.extension)
        return
      end
    end

    update_drive_items!(drive_items) do |drive_item|
      old_parent_id = drive_item.parent_id
      drive_item.update!(parent_id: new_parent_id)
      record_drive_item_event!(
        "drive_item.move",
        drive_item,
        changes: { parent_id: [ old_parent_id, new_parent_id ] },
        metadata: { bulk: true, count: drive_items.size }
      )
    end
    record_bulk_drive_item_event!("drive_item.bulk_move", parent_id: new_parent_id, count: drive_items.size) unless performed?

    render json: { message: "ファイルまたはフォルダを移動しました" } unless performed?
  end

  def bulk_delete
    result = DriveItems::TrashService.new(drive_items: active_drive_items_for_bulk.to_a).call
    unless result.success?
      render_api_error(error_code_for_status(result.status), result.message, status: result.status)
      return
    end

    record_bulk_drive_item_event!("drive_item.bulk_delete") unless performed?

    render json: { message: result.message } unless performed?
  end

  def bulk_restore
    if restore_resolution_items.present?
      restore_with_resolutions!(restore_resolution_items)
      return
    end

    deleted_drive_items_for_bulk.each do |drive_item|
      return unless restore_drive_item!(drive_item)
    end
    record_bulk_drive_item_event!("drive_item.bulk_restore") unless performed?

    render json: { message: "ファイルまたはフォルダを復元しました" } unless performed?
  end

  def bulk_download
    result = DriveItems::BulkDownloadService.new(
      organization: current_user.organization,
      drive_item_ids: params[:drive_item_ids]
    ).call

    unless result.success?
      render_api_error(error_code_for_status(result.status), result.error_message, status: result.status)
      return
    end

    record_bulk_download_access!(result.drive_items)
    send_zip_file(result)
  rescue StandardError => error
    result&.cleanup!
    Rails.logger.error("[drive_items.bulk_download] failed to send zip error=#{error.class}: #{error.message}")
    return if performed?

    render_api_error(:validation_failed, "ZIPファイルを送信できませんでした", status: :unprocessable_content)
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
    if restore_resolution_items.present?
      restore_with_resolutions!(restore_resolution_items)
      return
    end

    restored_item = restore_drive_item!(@drive_item)
    render json: drive_item_json(restored_item) if restored_item && !performed?
  end

  def restore_preview
    render json: restore_preview_json([ @drive_item ], restore_resolution_items)
  end

  def bulk_restore_preview
    drive_items = deleted_drive_items_for_bulk.to_a
    render json: restore_preview_json(drive_items, restore_resolution_items)
  end

  def purge
    result = DriveItems::PurgeService.new(drive_item: @drive_item, actor_user: current_user).call
    unless result.success?
      render_api_error(error_code_for_status(result.status), result.message, status: result.status)
      return
    end

    record_drive_item_event!("drive_item.purge", @drive_item, changes: { purged_at: [ nil, @drive_item.purged_at ] })
    render json: { message: result.message }
  end

  private

  def set_active_drive_item
    @drive_item = drive_item_query.find_active(params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def set_deleted_drive_item
    @drive_item = current_user.organization.drive_items.deleted.find_by(id: params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def set_deliverable_drive_item
    @drive_item = drive_item_query.find_deliverable(params[:id])
    return if @drive_item.present?

    render_not_found
  end

  def get_extension_from_filename(filename)
    File.extname(filename).delete_prefix(".").downcase
  end

  def normalized_parent_id
    parent_id = params[:parent_id]
    parent_id.present? ? parent_id.to_i : nil
  end

  def replace_trashed_drive_item_id
    params[:replace_trashed_drive_item_id].presence
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
      render_api_error(:invalid_parent, not_found_message, status: :not_found)
      return false
    end

    unless parent.directory?
      render_api_error(:invalid_parent, invalid_message, status: :unprocessable_content)
      return false
    end

    true
  end

  def duplicate_active_item?(parent_id:, name:, extension:, excluding_id: nil)
    scope = current_user
      .organization
      .drive_items
      .active
      .where(parent_id: parent_id, name: name, extension: extension)
    scope = scope.where.not(id: excluding_id) if excluding_id.present?
    scope.exists?
  end

  def active_drive_items_for_bulk
    current_user.organization.drive_items.active.where(id: bulk_drive_item_ids)
  end

  def deleted_drive_items_for_bulk
    current_user.organization.drive_items.deleted.where(id: bulk_drive_item_ids)
  end

  def bulk_drive_item_ids
    Array(params[:drive_item_ids].presence || params[:ids]).map(&:to_i)
  end

  def restore_resolution_items
    Array(params[:items]).filter_map do |item|
      next unless item.respond_to?(:permit)

      permitted = item.permit(
        :item_id,
        :resolution,
        :destination_parent_id,
        :expected_name,
        :expected_existing_item_id
      )
      permitted.to_h.symbolize_keys
    end
  end

  def restore_preview_json(drive_items, items)
    resolutions = items.index_by { |item| item.fetch(:item_id).to_i }
    DriveItems::RestorePreviewService.new(
      organization: current_user.organization,
      drive_items: drive_items,
      resolutions: resolutions
    ).as_json
  end

  def restore_with_resolutions!(items)
    result = DriveItems::RestoreResolutionService.new(
      organization: current_user.organization,
      actor_user: current_user,
      items: items
    ).call
    unless result.success?
      if result.preview.present?
        render_api_error(
          :restore_preview_stale,
          result.message,
          status: result.status,
          details: result.preview
        )
      else
        render_api_error(error_code_for_status(result.status), result.message, status: result.status)
      end
      return
    end

    result.items.each do |drive_item|
      record_drive_item_event!("drive_item.restore", drive_item, changes: { deleted_at: [ drive_item.deleted_at, nil ] })
    end
    render json: { message: result.message, restored_item_ids: result.items.map(&:id) }
  end

  def apply_drive_item_search(items, query)
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
    items.joins("LEFT JOIN users owner_users ON owner_users.id = drive_items.owner_user_id").where(
      "LOWER(drive_items.name) LIKE :pattern OR " \
      "LOWER(COALESCE(drive_items.extension, '')) LIKE :pattern OR " \
      "LOWER(COALESCE(owner_users.display_name, owner_users.name, '')) LIKE :pattern",
      pattern: pattern
    )
  end

  def drive_item_query
    @drive_item_query ||= DriveItems::Query.new(organization: current_user.organization)
  end

  def drive_item_json(drive_item, include_breadcrumbs: false)
    data = {
      id: drive_item.id,
      parent_id: drive_item.parent_id,
      parent_name: drive_item.parent&.name,
      name: drive_item.name,
      item_type: drive_item.item_type,
      extension: drive_item.extension,
      content_type: drive_item.content_type,
      file_size: drive_item.file_size,
      owner_user_id: drive_item.owner_user_id,
      owner_display_name: drive_item.owner_user&.safe_display_name,
      deleted_at: drive_item.deleted_at,
      created_at: drive_item.created_at,
      updated_at: drive_item.updated_at
    }
    data[:breadcrumbs] = breadcrumbs_for(drive_item) if include_breadcrumbs
    data
  end

  def breadcrumbs_for(drive_item)
    ancestors = []
    current = drive_item

    while current.present?
      return root_breadcrumbs if current.deleted_at.present?
      return root_breadcrumbs if current.organization_id != current_user.organization_id

      ancestors.unshift({ id: current.id, name: current.name })
      current = current.parent
    end

    root_breadcrumbs + ancestors
  end

  def root_breadcrumbs
    [ { id: nil, name: "共有ドライブ" } ]
  end

  def assign_parent_for_move!(drive_item, parent_id)
    return false if invalid_move_target?(drive_item, parent_id)
    return true if parent_id.blank? && drive_item.parent_id.nil?

    return false unless validate_parent_id(parent_id, not_found_message: "指定された移動先フォルダが見つかりません", invalid_message: "移動先にはフォルダーを指定してください")

    drive_item.parent_id = parent_id
    true
  end

  def invalid_move_target?(drive_item, parent_id)
    if parent_id.present? && parent_id.to_i == drive_item.id
      render_invalid_move("自分自身へ移動できません")
      return true
    end

    if drive_item.parent_id == parent_id
      render_invalid_move("同じ場所へは移動できません")
      return true
    end

    if parent_id.present? && drive_item.directory? && descendant_id?(drive_item, parent_id.to_i)
      render_invalid_move("フォルダーを自身の配下へ移動できません")
      return true
    end

    false
  end

  def descendant_id?(drive_item, parent_id)
    current = current_user.organization.drive_items.active.find_by(id: parent_id)
    while current.present?
      return true if current.parent_id == drive_item.id

      current = current.parent
    end
    false
  end

  def render_invalid_move(message)
    render_api_error(:validation_failed, message, status: :unprocessable_content)
    false
  end

  def render_duplicate_name(name, parent_id: nil, extension: nil)
    details = duplicate_name_details(name, parent_id:, extension:)
    render_api_error(
      details[:code],
      details[:message],
      status: :conflict,
      details: details.except(:code, :message)
    )
  end

  def render_active_content_duplicate(drive_item)
    render_api_error(
      :active_content_duplicate,
      "同じ内容のファイルが、この組織内にすでに存在します。",
      status: :conflict,
      details: {
        duplicate_kind: "same_content",
        duplicate_files: [ duplicate_content_file_json(drive_item) ],
        allowed_actions: [ "open_existing", "cancel" ]
      }
    )
  end

  def render_trash_content_duplicate(drive_item)
    render_api_error(
      :trash_content_duplicate,
      "同じ内容のファイルがゴミ箱にあります",
      status: :conflict,
      details: {
        duplicate_kind: "trash_content",
        duplicate: trash_duplicate_json(drive_item),
        allowed_actions: [ "restore", "upload_anyway", "cancel" ]
      }
    )
  end

  def error_code_for_status(status)
    case Rack::Utils.status_code(status)
    when 401 then :unauthorized
    when 403 then :forbidden
    when 404 then :not_found
    when 413 then :payload_too_large
    when 422 then :validation_failed
    when 500..599 then :internal_error
    else :validation_failed
    end
  end

  def render_name_conflict(name, parent_id: nil, extension: nil)
    render_duplicate_name(name, parent_id:, extension:)
  end

  def update_drive_items!(drive_items)
    ActiveRecord::Base.transaction do
      drive_items.each do |drive_item|
        yield drive_item
      end
    end
  rescue ActiveRecord::RecordInvalid => error
    render_validation_failed(error.record)
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error("[drive_items.bulk] failed error=#{error.class}: #{error.message}")
    render_api_error(:validation_failed, "一括操作に失敗しました", status: :unprocessable_content)
  end

  def save_uploaded_file(uploaded_file, storage_key)
    DriveItems::StoredFileInspector.copy_upload!(
      uploaded_file: uploaded_file,
      storage_path: DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key)),
      filename: uploaded_file.original_filename,
      storage_key: storage_key
    )
  end

  def replace_target_for_upload(upload_hash)
    replace_target = current_user.organization.drive_items.find_by(id: replace_trashed_drive_item_id)
    unless replace_target
      render_not_found
      return nil
    end
    if replace_target.purged_at.present?
      render_api_error(:replace_target_already_purged, "置換対象はすでに完全削除済みです", status: :conflict)
      return nil
    end
    if replace_target.deleted_at.blank?
      render_api_error(:replace_target_not_trashed, "置換対象はゴミ箱内にありません", status: :conflict)
      return nil
    end
    unless replace_target.file?
      render_api_error(:replace_target_mismatch, "置換対象がファイルではありません", status: :conflict)
      return nil
    end
    if replace_target.file_hash != upload_hash
      render_api_error(:replace_target_mismatch, "置換対象とアップロードファイルの内容が一致しません", status: :conflict)
      return nil
    end

    replace_target
  end

  def replace_trashed_upload!(uploaded_file:, upload_hash:, extension:, replace_target:)
    generated_storage_key = build_storage_key(extension)
    old_storage_key = replace_target.effective_storage_key
    file_saved = false
    committed = false

    begin
      stored_file = save_uploaded_file(uploaded_file, generated_storage_key)
      file_saved = true

      ActiveRecord::Base.transaction do
        replace_target.lock!
        validate_replace_target_state!(replace_target, upload_hash)

        @drive_item.storage_key = stored_file.storage_key
        @drive_item.extension = extension
        @drive_item.file_hash = stored_file.sha256
        @drive_item.file_size = stored_file.byte_size
        @drive_item.content_type = stored_file.content_type
        @drive_item.save!

        replace_target.update!(
          purged_at: Time.current,
          purged_by_user: current_user,
          trash_batch_id: nil,
          trashed_by_ancestor_id: nil,
          storage_key: nil,
          blob_path: nil
        )
      end
      committed = true

      record_drive_item_event!("drive_item.replace_trashed", @drive_item, metadata: {
        source: "trash_duplicate_invalid_parent_resolution",
        old_drive_item_id: replace_target.id,
        new_drive_item_id: @drive_item.id,
        original_name: replace_target.filename
      })
      cleanup_replaced_storage!(old_storage_key, replace_target.id)
      render json: drive_item_json(@drive_item), status: :created
    rescue ActiveRecord::RecordInvalid => error
      render_validation_failed(error.record)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("[drive_items.replace_trashed] failed error=#{error.class}: #{error.message}")
      render_api_error(:validation_failed, "ファイルを保存できませんでした", status: :unprocessable_content)
    rescue DriveItems::StoredFileInspector::UploadTooLargeError
      render_api_error(:payload_too_large, "ファイルサイズが上限を超えています", status: :content_too_large)
    ensure
      cleanup_uploaded_file!(generated_storage_key) if file_saved && !committed
    end
  end

  def validate_replace_target_state!(replace_target, upload_hash)
    raise ActiveRecord::RecordNotFound unless replace_target.organization_id == current_user.organization_id

    if replace_target.purged_at.present?
      raise ActiveRecord::RecordInvalid.new(replace_target.tap { |item| item.errors.add(:base, "置換対象はすでに完全削除済みです") })
    end
    if replace_target.deleted_at.blank?
      raise ActiveRecord::RecordInvalid.new(replace_target.tap { |item| item.errors.add(:base, "置換対象はゴミ箱内にありません") })
    end
    if !replace_target.file? || replace_target.file_hash != upload_hash
      raise ActiveRecord::RecordInvalid.new(replace_target.tap { |item| item.errors.add(:base, "置換対象とアップロードファイルの内容が一致しません") })
    end
  end

  def cleanup_replaced_storage!(storage_key, purged_drive_item_id)
    return if storage_key.blank?
    return unless DriveItem.valid_storage_key?(storage_key)
    return if DriveItem.not_purged.where(storage_key: storage_key).where.not(id: purged_drive_item_id).exists?
    return if DriveItem.not_purged.where(blob_path: DriveItem.storage_relative_path_for(storage_key)).where.not(id: purged_drive_item_id).exists?

    cleanup_uploaded_file!(storage_key)
  rescue StandardError => error
    Rails.logger.error("[drive_items.replace_trashed] cleanup failed drive_item_id=#{purged_drive_item_id} error=#{error.class}: #{error.message}")
  end

  def digest_uploaded_file(uploaded_file)
    io = uploaded_file.tempfile
    io.rewind
    digest = Digest::SHA256.new
    digest.update(io.read(5.megabytes)) until io.eof?
    digest.hexdigest
  ensure
    io&.rewind
  end

  def duplicate_name_details(name, parent_id:, extension:)
    suggested_name = next_available_name(parent_id:, name:, extension:)
    {
      code: :duplicate_name,
      message: "同じ名前のファイルまたはフォルダーが存在します。",
      field: "name",
      conflicting_name: display_filename(name, extension),
      duplicate_kind: "name",
      suggested_name: suggested_name,
      suggested_filename: display_filename(suggested_name, extension)
    }
  end

  def active_duplicate_item(parent_id:, name:, extension:)
    current_user.organization.drive_items.active.find_by(parent_id:, name:, extension:)
  end

  def active_content_duplicate_item(upload_hash)
    current_user
      .organization
      .drive_items
      .active
      .file
      .where(file_hash: upload_hash)
      .includes(:owner_user, :parent)
      .order(created_at: :desc, id: :desc)
      .detect { |drive_item| deleted_ancestor(drive_item).nil? }
  end

  def trash_content_duplicate_item(upload_hash)
    own_trash_duplicate = current_user
      .organization
      .drive_items
      .trashed
      .file
      .where(file_hash: upload_hash)
      .includes(:owner_user, :parent)
      .order(deleted_at: :desc, id: :desc)
      .first
    return own_trash_duplicate if own_trash_duplicate.present?

    current_user
      .organization
      .drive_items
      .active
      .file
      .where(file_hash: upload_hash)
      .includes(:owner_user, :parent)
      .order(created_at: :desc, id: :desc)
      .detect { |drive_item| deleted_ancestor(drive_item).present? }
  end

  def duplicate_content_file_json(drive_item)
    {
      id: drive_item.id,
      name: drive_item.filename,
      parent_id: drive_item.parent_id,
      parent_name: drive_item.parent&.name,
      owner_display_name: drive_item.owner_user&.safe_display_name,
      created_at: drive_item.created_at,
      file_size: drive_item.file_size,
      deleted: drive_item.deleted_at.present?
    }
  end

  def trash_duplicate_json(drive_item)
    restore_target = restore_target_for(drive_item)
    {
      id: drive_item.id,
      name: drive_item.name,
      extension: drive_item.extension,
      display_name: drive_item.filename,
      file_size: drive_item.file_size,
      content_type: drive_item.content_type,
      deleted_at: effective_deleted_at(drive_item)&.iso8601,
      original_parent: original_parent_json(drive_item.parent),
      uploaded_by: uploaded_by_json(drive_item.owner_user),
      restore_target: restore_target_json(restore_target)
    }
  end

  def restore_target_json(drive_item)
    return nil if drive_item.nil?

    {
      id: drive_item.id,
      type: drive_item.item_type,
      display_name: drive_item.filename
    }
  end

  def original_parent_json(parent)
    return nil if parent.nil?
    return nil if parent.organization_id != current_user.organization_id

    {
      id: parent.id,
      name: parent.name,
      path: drive_item_path(parent)
    }
  end

  def uploaded_by_json(user)
    return nil if user.nil?

    {
      id: user.id,
      display_name: user.safe_display_name
    }
  end

  def drive_item_path(drive_item)
    names = []
    current = drive_item
    while current.present? && current.organization_id == current_user.organization_id
      names.unshift(current.name)
      current = current.parent
    end
    "/#{names.join("/")}"
  end

  def restore_target_for(drive_item)
    DriveItems::RestoreService.new(drive_item: drive_item).restore_target
  end

  def effective_deleted_at(drive_item)
    drive_item.deleted_at || deleted_ancestor(drive_item)&.deleted_at
  end

  def deleted_ancestor(drive_item)
    current = drive_item.parent
    visited_ids = Set.new
    while current.present? && current.organization_id == current_user.organization_id
      return current if current.deleted_at.present? || current.purged_at.present?
      return if visited_ids.include?(current.id)

      visited_ids << current.id
      current = current.parent
    end
  end

  def allow_trash_duplicate?
    ActiveModel::Type::Boolean.new.cast(params[:allow_trash_duplicate])
  end

  def restore_drive_item!(drive_item)
    service = DriveItems::RestoreService.new(drive_item:)
    restore_target = service.restore_target
    return unless validate_parent_id(restore_target.parent_id, not_found_message: "復元先フォルダが見つかりません", invalid_message: "復元先にはディレクトリを指定してください")

    if duplicate_active_item?(parent_id: restore_target.parent_id, name: restore_target.name, extension: restore_target.extension, excluding_id: restore_target.id)
      render_duplicate_name(restore_target.name, parent_id: restore_target.parent_id, extension: restore_target.extension)
      return
    end

    before = restore_target.deleted_at
    result = service.call
    unless result.success?
      render_api_error(error_code_for_status(result.status), result.message, status: result.status)
      return
    end

    record_drive_item_event!("drive_item.restore", result.restore_target, changes: { deleted_at: [ before, nil ] })
    result.restore_target.reload
  end

  def next_available_name(parent_id:, name:, extension:)
    existing_names = current_user
      .organization
      .drive_items
      .active
      .where(parent_id:, extension:)
      .pluck(:name)
      .to_set
    return name unless existing_names.include?(name)

    index = 1
    loop do
      candidate = "#{name}（#{index}）"
      return candidate unless existing_names.include?(candidate)

      index += 1
    end
  end

  def display_filename(name, extension)
    extension.present? ? "#{name}.#{extension}" : name
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
      render_api_error(error_code_for_status(result.status), result.error_message, status: result.status)
      return
    end

    result.headers.each do |key, value|
      response.headers[key] = value
    end

    head result.status
  end

  def render_not_found
    render_api_error(:not_found, "指定されたファイルが見つかりません", status: :not_found)
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

  def record_drive_item_event!(action, drive_item, changes: {}, metadata: {})
    record_audit_event!(
      action: action,
      target: drive_item,
      organization: current_user.organization,
      changes: changes,
      metadata: metadata.merge(
        item_type: drive_item.item_type,
        name: drive_item.name,
        parent_id: drive_item.parent_id
      )
    )
  end

  def record_bulk_drive_item_event!(action, metadata = {})
    record_audit_event!(
      action: action,
      organization: current_user.organization,
      metadata: metadata.merge(
        drive_item_ids: bulk_drive_item_ids
      )
    )
  end

  def changed_values(before, after)
    before.each_with_object({}) do |(key, old_value), changes|
      new_value = after[key]
      changes[key] = [ old_value, new_value ] if old_value != new_value
    end
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
