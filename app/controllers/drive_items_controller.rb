class DriveItemsController < ApplicationController

  # ログインしていない利用者は、このコントローラの操作をできない
  before_action :authenticate_user!

  def index
  end

  def show
  end
end
