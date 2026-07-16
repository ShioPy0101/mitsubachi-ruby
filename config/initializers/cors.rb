if Rails.env.development?
  class DevelopmentCors
    DEFAULT_ORIGINS = %w[
      http://localhost:5173
      http://127.0.0.1:5173
    ].freeze

    def initialize(app)
      @app = app
      @allowed_origins = ENV.fetch(
        "FRONTEND_ORIGIN",
        DEFAULT_ORIGINS.join(",")
      ).split(",")
       .map(&:strip)
       .reject(&:blank?)
    end

    def call(env)
      origin = env["HTTP_ORIGIN"]
      return @app.call(env) unless @allowed_origins.include?(origin)

      if env["REQUEST_METHOD"] == "OPTIONS"
        return [204, cors_headers(origin), []]
      end

      status, headers, body = @app.call(env)
      [status, headers.merge(cors_headers(origin)), body]
    end

    private

    def cors_headers(origin)
      {
        "Access-Control-Allow-Origin" => origin,
        "Access-Control-Allow-Credentials" => "true",
        "Access-Control-Allow-Methods" =>
          "GET, POST, PATCH, PUT, DELETE, OPTIONS, HEAD",
        "Access-Control-Allow-Headers" =>
          "Origin, Content-Type, Accept, X-CSRF-Token, X-Requested-With",
        "Vary" => "Origin"
      }
    end
  end

  Rails.application.config.middleware.insert_before 0, DevelopmentCors
end