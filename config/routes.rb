Rails.application.routes.draw do
  devise_for :users, skip: [:sessions, :registrations]

  # 認証コードを発行・メール送信
  post "/auth/email", to: "email_authentications#create"

  # 認証コードを照合してログイン
  post "/auth/verify", to: "email_authentications#verify"

  # ログアウト
  delete "/logout", to: "sessions#destroy"
end