require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module MitsubachiRuby
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "Tokyo"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    config.session_store(
      :cookie_store,
      key: "_mitsubachi_ruby_session",
      httponly: true,
      same_site: :lax,
      secure: Rails.env.production?
    )
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use config.session_store, config.session_options

    config.action_dispatch.default_headers.merge!(
      "X-Frame-Options" => "DENY",
      "X-Content-Type-Options" => "nosniff",
      "Referrer-Policy" => "no-referrer",
      "Permissions-Policy" => "camera=(), microphone=(), geolocation=()"
    )

    config.x.file_storage_root = ENV.fetch("FILE_STORAGE_ROOT", Rails.root.join("storage").to_s)
    config.x.max_upload_size_bytes = ENV.fetch("MAX_UPLOAD_SIZE_BYTES", 10.gigabytes.to_s).to_i
  end
end
