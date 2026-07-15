require "cgi"
require "uri"

class ProductionDatabaseConfigValidator
  Error = Class.new(StandardError)

  EXPECTED_USERNAME = "mitsubachi"
  EXPECTED_HOST = "127.0.0.1"
  EXPECTED_PORT = 5432

  REQUIRED_DATABASES = {
    "primary" => [ "DATABASE_URL", "mitsubachi_production" ],
    "cache" => [ "DATABASE_CACHE_URL", "mitsubachi_production_cache" ],
    "queue" => [ "DATABASE_QUEUE_URL", "mitsubachi_production_queue" ],
    "cable" => [ "DATABASE_CABLE_URL", "mitsubachi_production_cable" ]
  }.freeze

  def self.validate!(env: ENV, out: $stdout)
    new(env:, out:).validate!
  end

  def initialize(env:, out:)
    @env = env
    @out = out
    @errors = []
    @inspected = []
  end

  def validate!
    REQUIRED_DATABASES.each do |name, (env_name, expected_database)|
      inspect_database(name, env_name, expected_database)
    end

    write_inspection
    raise Error, error_message if errors.any?

    true
  end

  private

  attr_reader :env, :out, :errors, :inspected

  def inspect_database(name, env_name, expected_database)
    raw_url = env[env_name].to_s
    if raw_url.empty?
      inspected << inspection_row(name:, env_name:, uri: nil)
      errors << "#{name}: #{env_name} is not set"
      return
    end

    uri = URI.parse(raw_url)
    inspected << inspection_row(name:, env_name:, uri:)
    validate_uri(name, env_name, expected_database, uri)
  rescue URI::InvalidURIError
    inspected << inspection_row(name:, env_name:, uri: nil)
    errors << "#{name}: #{env_name} is not a valid PostgreSQL URL"
  end

  def validate_uri(name, env_name, expected_database, uri)
    errors << "#{name}: #{env_name} must use postgres or postgresql scheme" unless [ "postgres", "postgresql" ].include?(uri.scheme)
    errors << "#{name}: host must be #{EXPECTED_HOST}" unless uri.host == EXPECTED_HOST
    errors << "#{name}: port must be #{EXPECTED_PORT}" unless uri.port == EXPECTED_PORT
    errors << "#{name}: database must be #{expected_database}" unless database_name(uri) == expected_database
    errors << "#{name}: username must be #{EXPECTED_USERNAME}" unless username(uri) == EXPECTED_USERNAME
    errors << "#{name}: password must be set" unless password_present?(uri)
  end

  def inspection_row(name:, env_name:, uri:)
    {
      name:,
      env_name:,
      host: uri&.host,
      port: uri&.port,
      database: uri && database_name(uri),
      username: uri && username(uri),
      password_present: uri && password_present?(uri)
    }
  end

  def write_inspection
    out.puts "== Production database configuration =="
    inspected.each do |row|
      out.puts [
        row.fetch(:name),
        "env=#{row.fetch(:env_name)}",
        "host=#{row.fetch(:host).presence || "(empty)"}",
        "port=#{row.fetch(:port).presence || "(empty)"}",
        "database=#{row.fetch(:database).presence || "(empty)"}",
        "username=#{row.fetch(:username).presence || "(empty)"}",
        "password_set=#{row.fetch(:password_present) ? "yes" : "no"}"
      ].join(" ")
    end
  end

  def error_message
    "production database configuration is invalid:\n- #{errors.join("\n- ")}"
  end

  def database_name(uri)
    uri.path.to_s.delete_prefix("/")
  end

  def username(uri)
    CGI.unescape(uri.user.to_s)
  end

  def password_present?(uri)
    uri.password.to_s != ""
  end
end
