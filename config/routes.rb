Rails.application.routes.draw do
  # /drive_items を中心に、DriveItemsController のCRUDルートを作成
  # 自動生成されるルート:
  # GET    /drive_items          -> drive_items#index
  # POST   /drive_items          -> drive_items#create
  # GET    /drive_items/:id      -> drive_items#show
  # PATCH  /drive_items/:id      -> drive_items#update
  # DELETE /drive_items/:id      -> drive_items#destroy
  resources :drive_items do
    # collection は「特定の1件ではなく、drive_items 全体」を対象にする操作
    # URLに :id は付かない
    collection do
      # GET /drive_items/trash
      # 論理削除済みのファイル・ディレクトリ一覧を返す
      get :trash

      # POST /drive_items/bulk_move
      # 複数選択した項目を、指定したフォルダへまとめて移動
      post :bulk_move

      # POST /drive_items/bulk_delete
      # 複数選択した項目をまとめてゴミ箱へ移動
      post :bulk_delete

      # POST /drive_items/bulk_restore
      # ゴミ箱にある複数項目をまとめて復元
      post :bulk_restore

      # POST /drive_items/bulk_download
      # 複数ファイルをまとめてZIP化してダウンロード
      post :bulk_download
    end

    # member は「特定の1件」を対象にする操作
    # URLに対象のIDが付く。
    member do
      # GET /drive_items/:id/preview
      # 画像・PDF・動画などをブラウザ内で表示
      get :preview

      # GET /drive_items/:id/download
      # 1件のファイルをダウンロード
      get :download

      # POST /drive_items/:id/restore
      # ゴミ箱にある1件を復元
      post :restore
    end
  end

  devise_for :users, skip: [ :sessions, :registrations ]

  # 認証コードを発行・メール送信（アカウント作成用）
  post "/auth/create", to: "email_authentications#create"

  # 認証コードを発行・メール送信（ログイン用）
  post "/auth/login", to: "email_authentications#login"

  # 認証コードを照合してログイン
  post "/auth/verify", to: "email_authentications#verify"

  # ログアウト
  delete "/logout", to: "sessions#destroy"
end
