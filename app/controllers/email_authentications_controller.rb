class EmailAuthenticationsController < ApplicationController
  def create
    # POST /auth/email
    # JSONで受けた email を使って
    # 6桁コードを作り、DB保存し、メール送信する
  end

  def verify
    # POST /auth/verify
    # JSONで受けた email と code を照合する
    # 成功したらログイン状態を作る
  end
end