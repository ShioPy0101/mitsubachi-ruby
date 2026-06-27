Rails.application.routes.draw do
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
