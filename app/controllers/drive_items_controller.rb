
require "fileutils"
require "securerandom"
require "rack/mime"


class DriveItemsController < ApplicationController
  # ログインしていない利用者は、このコントローラの操作をできない
  before_action :authenticate_user!

  # 1件の DriveItem を対象にするアクションの前に実行する
  before_action :set_drive_item, only: %i[
    show
    update
    destroy
    preview
    download
    restore
  ]

  # GET /drive_items
  # ルート直下、または指定フォルダ直下の一覧を返す
  def index
      @drive_items =
      current_user.organization
                  .drive_items
                  .active
                  .where(parent_id: params[:parent_id])
                  .order(item_type: :desc, name: :asc)
      render json: @drive_items
  end

  # POST /drive_items
  # フォルダ作成・ファイル登録
  def create
    name = params[:name] # ファイル名またはフォルダ名
    parent_id = params[:parent_id] # 親フォルダのID。ルート直下の場合は nil
    item_type = params[:item_type] # file or directory

    if item_type != "file" && item_type != "directory"
      render json: { error: "ファイルタイプは file または directory のいずれかである必要があります" }, status: :unprocessable_entity
      return
    end

    if item_type == "file" && params[:file].nil?
      render json: { error: "ファイルが指定されていません" }, status: unprocessable_entity
      return
    end

    if item_type == "directory" && params[:file].present?
      render json: { error: "ディレクトリ作成時にファイルは指定できません" }, status: :unprocessable_entity
      return
    end

    if parent_id.present?
      # 組織内の親フォルダを検索する。親フォルダが見つからない場合はエラーを返す
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
      owner_user: current_user,
    )

    # ファイルの場合は、拡張子・保存先パス・ハッシュを設定する
    if item_type == "file"
      # ActionDispatch::Http::UploadedFile
      uploaded_file = params[:file]

      blob_path, extension = save_uploaded_file(uploaded_file)

      @drive_item.blob_path = blob_path
      @drive_item.extension = extension
      @drive_item.file_hash = nil

      if  @drive_item.save
        # レスポンス
        render json: @drive_item, status: :created
      else
        FileUtils.rm_f(Rails.root.join("storage", blob_path))
        render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
      end

    else
      # ディレクトリの場合は、拡張子・保存先パスは不要
      @drive_item.extension = nil
      @drive_item.blob_path = nil
      @drive_item.file_hash = nil

      if @drive_item.save
        render json: @drive_item, status: :created
      else
        render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end

  # GET /drive_items/:id
  # ファイルまたはフォルダの詳細を返す
  def show
    drive_item_id = params[:id]

    # 組織内の DriveItem を検索する。見つからない場合はエラーを返す
    @drive_item = current_user.organization.drive_items.active.find_by(id: drive_item_id)

    if @drive_item.nil?
      render json: { error: "指定されたファイルまたはフォルダが見つかりません" }, status: :not_found
    else
      render json: @drive_item
    end
  end

  # PATCH /drive_items/:id
  # 名前変更・単体移動など
  def update
    drive_item_id = params[:id]
    new_name = params[:name]
    new_parent_id = params[:parent_id]

    # 組織内の DriveItem を検索する。見つからない場合はエラーを返す
    @drive_item = current_user.organization.drive_items.active.find_by(id: drive_item_id)

    if @drive_item.nil?
      render json: { error: "指定されたファイルまたはフォルダが見つかりません" }, status: :not_found
      return
    end

    if new_name.present?
      # 名前変更
      @drive_item.name = new_name
    end

    if new_parent_id.present?
      # 移動先の親フォルダを検索する。見つからない場合はエラーを返す
      new_parent = current_user.organization.drive_items.active.find_by(id: new_parent_id)

      if new_parent.nil?
        render json: { error: "指定された新しい親フォルダが見つかりません" }, status: :not_found
        return
      end

      unless new_parent.directory?
        # unprocessable_entityは422エラー。リクエストは正しいが、処理できない場合に使う

        render json: { error: "新しい親にはディレクトリを指定してください" }, status: :unprocessable_entity
        return
      end

      @drive_item.parent_id = new_parent_id
    end

    if @drive_item.save
      render json: @drive_item
    else
      render json: { errors: @drive_item.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /drive_items/:id
  # 論理削除してゴミ箱へ移動
  def destroy
    drive_item_id = params[:id]

    # 組織内の DriveItem を検索する。見つからない場合はエラーを返す
    @drive_item = current_user.organization.drive_items.active.find_by(id: drive_item_id)

    if @drive_item.nil?
      render json: { error: "指定されたファイルまたはフォルダが見つかりません" }, status: :not_found
      return
    end

    # 論理削除（ゴミ箱へ移動）
    @drive_item.update(deleted_at: Time.current)

    render json: { message: "ファイルまたはフォルダをゴミ箱に移動しました" }
  end

  # GET /drive_items/trash
  # ゴミ箱一覧
  def trash
    @drive_items =
      current_user.organization
                  .drive_items
                  .deleted
                  .order(deleted_at: :desc)
    render json: @drive_items
  end

  # POST /drive_items/bulk_move
  # 複数項目を指定フォルダへ移動
  def bulk_move
    drive_item_ids = params[:drive_item_ids]
    new_parent_id = params[:parent_id]

    # 移動先の親フォルダを検索する。見つからない場合はエラーを返す
    new_parent = current_user.organization.drive_items.active.find_by(id: new_parent_id)

    if new_parent.nil?
      render json: { error: "指定された新しい親フォルダが見つかりません" }, status: :not_found
      return
    end

    unless new_parent.directory?
      render json: { error: "新しい親にはディレクトリを指定してください" }, status: :unprocessable_entity
      return
    end

    # 指定された DriveItem を検索し、親フォルダを更新する
    @drive_items = current_user.organization.drive_items.active.where(id: drive_item_ids)
    @drive_items.update_all(parent_id: new_parent_id)

    render json: { message: "ファイルまたはフォルダを移動しました" }
  end

  # POST /drive_items/bulk_delete
  # 複数項目をまとめて論理削除
  def bulk_delete
    drive_item_ids = params[:drive_item_ids]

    # 指定された DriveItem を検索し、論理削除（ゴミ箱へ移動）する
    @drive_items = current_user.organization.drive_items.active.where(id: drive_item_ids)
    @drive_items.update_all(deleted_at: Time.current)

    render json: { message: "ファイルまたはフォルダをゴミ箱に移動しました" }
  end

  # POST /drive_items/bulk_restore
  # 複数項目をまとめて復元
  def bulk_restore
    drive_item_ids = params[:drive_item_ids]

    # 指定された DriveItem を検索し、論理削除を解除（復元）する
    @drive_items = current_user.organization.drive_items.deleted.where(id: drive_item_ids)
    @drive_items.update_all(deleted_at: nil)

    render json: { message: "ファイルまたはフォルダを復元しました" }
  end

  # POST /drive_items/bulk_download
  # 複数ファイルを ZIP にまとめる
  def bulk_download
  end

  # GET /drive_items/:id/preview
  # ブラウザ内プレビュー(動画を返す)
  def preview
    return unless prepare_accel_redirect!("inline")

    head :ok
  end

  # GET /drive_items/:id/download
  # ファイルダウンロード
  def download
    return unless prepare_accel_redirect!("attachment")

    head :ok
  end

  # POST /drive_items/:id/restore
  # 1件だけゴミ箱から復元
  def restore
  end

  private

  # 他組織のファイルを URL の id 指定だけで取得できないように、
  # ログイン中ユーザーの organization を起点に検索する
  def set_drive_item
    @drive_item =
      current_user.organization
                  .drive_items
                  .find(params[:id])
  end

  # multipart/form-dataかチェック
  def check_file_type(file)
    # multipart/form-data で送信されたファイルかどうかをチェックする
    unless file.is_a?(ActionDispatch::Http::UploadedFile)
      render json: { error: "ファイルが正しく送信されていません" }, status: :unprocessable_entity
      return false
    end
    true
  end

  # 拡張子取得
  def get_extension_from_filename(filename)
    File.extname(filename).delete_prefix(".").downcase
  end

  def save_uploaded_file(uploaded_file)
    # ファイルの拡張子を取得し、保存先のパスを生成する
    extension = get_extension_from_filename(uploaded_file.original_filename)

    # 保存先のパスを生成する。UUIDを使って一意にする
    storage_key = "drive_items/#{SecureRandom.uuid}.#{extension}"
    destination_path = Rails.root.join("storage", storage_key)

    # storage/drive_items がまだなければ作る
    FileUtils.mkdir_p(destination_path.dirname)

    # 一時ファイルから保存先へコピーする。
    # ファイル全体をRubyのメモリに載せない。
    uploaded_file.tempfile.rewind
    File.open(destination_path, "wb") do |file|
      IO.copy_stream(uploaded_file.tempfile, file)
    end

    [ storage_key, extension ]
  end

  # X-Accel-Redirectによるファイル配信の準備を行う。
  #
  # 配信可能なファイルか、保存先キーが安全か、実ファイルが存在するかを確認し、
  # 問題がなければアクセスログとレスポンスヘッダーを設定する。
  #
  # 戻り値:
  # - 成功時: true
  # - 失敗時: エラーレスポンスを返して false
  def prepare_accel_redirect!(disposition)
    # フォルダなど、ファイル以外のDriveItemは配信できない。
    unless @drive_item.file?
      render json: { error: "この操作はファイルに対してのみ可能です" },
            status: :unprocessable_entity
      return false
    end

    # 実際の保存先を表すストレージキーを取得する。
    storage_key = @drive_item.effective_storage_key

    # 不正なパスやパストラバーサルを防ぐため、
    # ストレージキーの形式を検証する。
    unless DriveItem.valid_storage_key?(storage_key)
      render json: { error: "保存先キーが不正です" }, status: :not_found
      return false
    end

    # ストレージキーから、Railsサーバー上の絶対パスを生成する。
    absolute_path = storage_absolute_path(storage_key)

    # DB上にDriveItemが存在していても、
    # 実ファイルが削除されている可能性があるため存在確認する。
    unless File.exist?(absolute_path)
      render json: { error: "ファイルが見つかりません" }, status: :not_found
      return false
    end

    # inlineならプレビュー、それ以外ならダウンロードとして記録する。
    action = disposition == "inline" ? "preview" : "download"
    record_drive_item_access!(action)

    # Nginxに内部配信させるためのレスポンスヘッダーを設定する。
    apply_accel_redirect_headers(storage_key, disposition)

    true
  end

  # ストレージキーから、Railsプロジェクト内の実ファイルパスを生成する。
  #
  # 例:
  # storage_key = "organizations/1/files/example.pdf"
  # 戻り値 = Rails.root/storage/organizations/1/files/example.pdf
  def storage_absolute_path(storage_key)
    Rails.root.join("storage", storage_key)
  end

  # X-Accel-Redirectによる配信に必要なレスポンスヘッダーを設定する。
  def apply_accel_redirect_headers(storage_key, disposition)
    # Railsがファイル本体を返す代わりに、
    # Nginxへ内部配信先のURIを通知する。
    response.headers["X-Accel-Redirect"] =
      "/internal/storage/#{storage_key}"

    # 拡張子からMIMEタイプを判定する。
    # 判定できない場合はapplication/octet-streamを使用する。
    response.headers["Content-Type"] =
      drive_item_content_type(@drive_item)

    # inlineならブラウザ表示、attachmentならダウンロードを指示する。
    # ContentDisposition.formatを使うことで、
    # 日本語や特殊文字を含むファイル名も適切にエンコードされる。
    response.headers["Content-Disposition"] =
      ActionDispatch::Http::ContentDisposition.format(
        disposition: disposition,
        filename: drive_item_filename(@drive_item)
      )
  end

  # DriveItemの拡張子からContent-Typeを取得する。
  #
  # MIMEタイプが見つからない場合は、
  # 汎用バイナリ形式のapplication/octet-streamを返す。
  def drive_item_content_type(drive_item)
    Rack::Mime.mime_type(
      ".#{drive_item.extension}",
      "application/octet-stream"
    )
  end

  # ダウンロード時に使用するファイル名を生成する。
  #
  # nameに既に拡張子が含まれている場合はそのまま返し、
  # 含まれていない場合だけ拡張子を追加する。
  def drive_item_filename(drive_item)
    extension = drive_item.extension.to_s

    # 拡張子が登録されていない場合は、nameをそのまま使用する。
    return drive_item.name if extension.blank?

    # 大文字・小文字を無視して、既に同じ拡張子が付いているか確認する。
    return drive_item.name if drive_item.name.downcase.end_with?(
      ".#{extension.downcase}"
    )

    "#{drive_item.name}.#{extension}"
  end

  # ファイルのプレビューまたはダウンロード履歴を記録する。
  def record_drive_item_access!(action)
    DriveItemAccessLog.create!(
      # ログの所属組織は、現在ログインしているユーザーの組織とする。
      organization: current_user.organization,

      # 誰がアクセスしたかを記録する。
      user: current_user,

      # どのファイルへアクセスしたかを記録する。
      drive_item: @drive_item,

      # previewまたはdownloadを記録する。
      action: action,

      # 実際にアクセス処理が行われた時刻を記録する。
      accessed_at: Time.current
    )
  end
end
