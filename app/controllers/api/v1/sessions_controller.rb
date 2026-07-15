class Api::V1::SessionsController < ApplicationController
  before_action :authenticate_user!

  def destroy
    sign_out(current_user)
    reset_session
    head :no_content
  end
end
