
require "fileutils"
require "securerandom"


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
    name = params[:name] #ファイル名またはフォルダ名
    parent_id = params[:parent_id] #親フォルダのID。ルート直下の場合は nil
    item_type = params[:item_type] #file or directory

    if item_type != "file" && item_type != "directory"
      render json: { error: "ファイルタイプは file または directory のいずれかである必要があります" }, status: :unprocessable_entity
      return
    end

    if item_type == "file" && params[:file].nil?
      render json: { error: "ファイルが指定されていません" }, status:unprocessable_entity
      return
    end

    if item_type == "directory" && params[:file].present?
      render json: { error: "ディレクトリ作成時にファイルは指定できません" }, status: :unprocessable_entity
      return
    end

    if parent_id.present?
      # 組織内の親フォルダを検索する。親フォルダが見つからない場合はエラーを返す
      parent = current_user.organization.drive_items.find_by(id: parent_id)
      if parent.nil?
        render json: { error: "指定された親フォルダが見つかりません" }, status: :not_found
        return
      end 

      unless parent.directory?
        render json: { error: "親にはディレクトリを指定してください" }, status: :unprocessable_entity
        return
      end
    end

    if current_user.organization.drive_items.exists?(parent_id: parent_id, name: name, extension: item_type == "file" ? File.extname(params[:file].original_filename).delete_prefix(".") : nil)
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
        File.delete(Rails.root.join("storage", blob_path))
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
  end

  # PATCH /drive_items/:id
  # 名前変更・単体移動など
  def update
  end

  # DELETE /drive_items/:id
  # 論理削除してゴミ箱へ移動
  def destroy
  end

  # GET /drive_items/trash
  # ゴミ箱一覧
  def trash
  end

  # POST /drive_items/bulk_move
  # 複数項目を指定フォルダへ移動
  def bulk_move
  end

  # POST /drive_items/bulk_delete
  # 複数項目をまとめて論理削除
  def bulk_delete
  end

  # POST /drive_items/bulk_restore
  # 複数項目をまとめて復元
  def bulk_restore
  end

  # POST /drive_items/bulk_download
  # 複数ファイルを ZIP にまとめる
  def bulk_download
  end

  # GET /drive_items/:id/preview
  # ブラウザ内プレビュー
  def preview
  end

  # GET /drive_items/:id/download
  # ファイルダウンロード
  def download
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

  def save_uploaded_file(uploaded_file)
    # ファイルの拡張子を取得し、保存先のパスを生成する
    extension =
      File.extname(uploaded_file.original_filename)
          .delete_prefix(".")
          .downcase

    # 保存先のパスを生成する。UUIDを使って一意にする
    blob_path = "drive_items/#{SecureRandom.uuid}.#{extension}"
    destination_path = Rails.root.join("storage", blob_path)

    # storage/drive_items がまだなければ作る
    FileUtils.mkdir_p(destination_path.dirname)

    # 一時ファイルから保存先へコピーする。
    # ファイル全体をRubyのメモリに載せない。
    uploaded_file.tempfile.rewind
    File.open(destination_path, "wb") do |file|
      IO.copy_stream(uploaded_file.tempfile, file)
    end

    [blob_path, extension]
  end

end