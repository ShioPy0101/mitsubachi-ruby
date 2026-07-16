class ApiCors
  DEVELOPMENT_ORIGINS = %w[
    http://localhost:5173
    http://127.0.0.1:5173
  ].freeze

  PRODUCTION_ORIGINS = %w[
    https://drive.shiosalt.com
  ].freeze

  def initialize(app)
    @app = app
    @allowed_origins = configured_origins
  end

  def call(env)
    origin = env["HTTP_ORIGIN"]
    return @app.call(env) unless @allowed_origins.include?(origin)

    if env["REQUEST_METHOD"] == "OPTIONS"
      return [ 204, cors_headers(origin), [] ]
    end

    status, headers, body = @app.call(env)
    [ status, headers.merge(cors_headers(origin, headers["Vary"])), body ]
  end

  private

  def configured_origins
    ENV.fetch("FRONTEND_ORIGIN", default_origins.join(","))
       .split(",")
       .map(&:strip)
       .reject(&:blank?)
  end

  def default_origins
    if Rails.env.production?
      PRODUCTION_ORIGINS
    else
      DEVELOPMENT_ORIGINS
    end
  end

  def cors_headers(origin, existing_vary = nil)
    {
      "Access-Control-Allow-Origin" => origin,
      "Access-Control-Allow-Credentials" => "true",
      "Access-Control-Allow-Methods" =>
        "GET, POST, PATCH, PUT, DELETE, OPTIONS, HEAD",
      "Access-Control-Allow-Headers" =>
        "Origin, Content-Type, Accept, X-CSRF-Token, X-Requested-With",
      "Vary" => vary_header(existing_vary)
    }
  end

  def vary_header(existing_vary)
    values = existing_vary.to_s.split(",").map(&:strip).reject(&:blank?)
    (values | [ "Origin" ]).join(", ")
  end
end

Rails.application.config.middleware.insert_before 0, ApiCors
