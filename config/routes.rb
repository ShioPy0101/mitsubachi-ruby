Rails.application.routes.draw do
  # Deviseはログイン状態の管理のみ使用
  devise_for :users, skip: [:sessions, :registrations]

  # メールアドレス入力画面
  get  "/auth/email", to: "email_authentications#new"

  # 6桁コードを発行してメール送信
  post "/auth/email", to: "email_authentications#create"

  # 6桁コード入力画面
  get  "/auth/verify", to: "email_authentications#verify_form"

  # 6桁コードを確認してログインする
  post "/auth/verify", to: "email_authentications#verify"

  # ログアウト
  delete "/logout", to: "sessions#destroy"
end