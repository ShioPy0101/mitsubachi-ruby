Rails.application.routes.draw do
  devise_for :users, skip: :all

  namespace :api do
    get "health", to: "health#ready"
    get "health/live", to: "health#live"
    get "health/ready", to: "health#ready"

    namespace :v1 do
      resource :csrf_token, only: :show
      resource :me, only: %i[show update], controller: :me do
        post "email_change", action: :request_email_change
        post "email_change/verify", action: :verify_email_change
        delete "email_change", action: :cancel_email_change
      end
      resource :group, only: %i[show update], controller: :groups
      post "upload_metrics", to: "upload_metrics#create"
      patch "upload_metrics/:upload_session_id", to: "upload_metrics#update"
      post "organizations/:organization_id/upload_metrics", to: "upload_metrics#create"
      patch "organizations/:organization_id/upload_metrics/:upload_session_id", to: "upload_metrics#update"
      resources :external_shares, only: %i[index show create update destroy] do
        member do
          post :regenerate_password
        end
      end

      namespace :public do
        get "shares/:token", to: "shares#show"
        post "shares/:token/unlock", to: "shares#unlock"
        get "shares/:token/items", to: "shares#items"
        get "shares/:token/items/:drive_item_id", to: "shares#item"
        get "shares/:token/items/:drive_item_id/preview", to: "shares#preview"
        get "shares/:token/items/:drive_item_id/thumbnail", to: "shares#thumbnail"
        get "shares/:token/items/:drive_item_id/download", to: "shares#download"
        post "shares/:token/bulk_download", to: "shares#bulk_download"
      end

      namespace :admin do
        resource :dashboard, only: :show
        resources :organizations, only: %i[index show create update]
        resources :organization_invites, only: :create
        resources :users, only: %i[index show update] do
          member do
            patch :suspend
            patch :unsuspend
          end
        end
        resources :drive_items, only: %i[index show destroy] do
          member do
            get :preview
            get :download
            get :stream
            delete :purge
            patch :restore
          end
        end
        resources :operation_logs, only: %i[index show]
        resources :drive_item_access_logs, only: %i[index show]
      end

      resources :organizations, only: [] do
        resource :group, only: %i[show update], controller: :groups
        resources :external_shares, only: %i[index show create update destroy] do
          member do
            post :regenerate_password
          end
        end

        namespace :admin do
          resource :dashboard, only: :show
          resources :organization_invites, only: :create
          resources :users, only: %i[index show update] do
            member do
              patch :suspend
              patch :unsuspend
            end
          end
          resources :drive_items, only: %i[index show destroy] do
            member do
              get :preview
              get :download
              get :stream
              delete :purge
              patch :restore
            end
          end
          resources :operation_logs, only: %i[index show]
          resources :drive_item_access_logs, only: %i[index show]
          resources :system_events, only: %i[index show]
        end

        resources :drive_items do
          collection do
            get :search
            get :check_name
            get :trash
            post :bulk_move
            post :bulk_delete
            delete :bulk_purge
            post :bulk_restore_preview
            post :bulk_restore
            post :bulk_download
          end

          member do
            get :preview
            get :thumbnail
            get :download
            get :stream
            patch :move
            post :restore_preview
            post :restore
            delete :purge
          end
        end
      end

      namespace :system_admin do
        resources :system_events, only: %i[index show]
        get "upload_metrics/summary", to: "upload_metrics#summary"
        get "upload_metrics/timeseries", to: "upload_metrics#timeseries"
        resources :upload_metrics, only: %i[index show]
      end

      post "auth/create", to: "email_authentications#create"
      post "auth/login", to: "email_authentications#login"
      post "auth/verify", to: "email_authentications#verify"
      post "auth/registration/verify", to: "email_authentications#verify_registration"
      post "auth/login/verify", to: "email_authentications#verify_login"
      delete "logout", to: "sessions#destroy"
      get "organization_invitations/:token",
          to: "organization_invitations#show",
          as: :organization_invitation
      post "organization_invitations/:token/accept",
           to: "organization_invitations#accept",
           as: :accept_organization_invitation

      resources :drive_items do
        collection do
          get :search
          get :check_name
          get :trash
          post :bulk_move
          post :bulk_delete
          delete :bulk_purge
          post :bulk_restore_preview
          post :bulk_restore
          post :bulk_download
        end

        member do
          get :preview
          get :thumbnail
          get :download
          get :stream
          patch :move
          post :restore_preview
          post :restore
          delete :purge
        end
      end

      resources :organizations, only: [] do
        resources :drive_items, controller: :drive_items do
          collection do
            get :search
            get :check_name
            get :trash
            post :bulk_move
            post :bulk_delete
            delete :bulk_purge
            post :bulk_restore_preview
            post :bulk_restore
            post :bulk_download
          end

          member do
            get :preview
            get :thumbnail
            get :download
            get :stream
            patch :move
            post :restore_preview
            post :restore
            delete :purge
          end
        end
      end
    end
  end
end
