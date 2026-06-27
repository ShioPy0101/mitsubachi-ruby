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
end