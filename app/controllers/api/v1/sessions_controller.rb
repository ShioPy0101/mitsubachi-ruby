class Api::V1::SessionsController < ApplicationController
  before_action :authenticate_user!

  def destroy
    destroy_authenticated_session!
    head :no_content
  end
end
