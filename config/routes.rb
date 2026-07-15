Rails.application.routes.draw do
  devise_for :users, skip: :all

  namespace :api do
    get "health", to: "health#ready"
    get "health/live", to: "health#live"
    get "health/ready", to: "health#ready"

    namespace :v1 do
      resource :csrf_token, only: :show

      namespace :admin do
        resource :dashboard, only: :show
        resources :organizations, only: %i[index show update]
        resources :users, only: %i[index show update] do
          member do
            patch :suspend
            patch :unsuspend
          end
        end
        resources :drive_items, only: %i[index show destroy] do
          member do
            patch :restore
          end
        end
        resources :audit_logs, only: %i[index show]
      end

      post "auth/create", to: "email_authentications#create"
      post "auth/login", to: "email_authentications#login"
      post "auth/verify", to: "email_authentications#verify"
      delete "logout", to: "sessions#destroy"

      resources :drive_items do
        collection do
          get :trash
          post :bulk_move
          post :bulk_delete
          post :bulk_restore
          post :bulk_download
        end

        member do
          get :preview
          get :download
          get :stream
          post :restore
        end
      end
    end
  end
end
