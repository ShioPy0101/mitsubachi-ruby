require "test_helper"
require "erb"
require "yaml"

class DatabaseConfigurationTest < ActiveSupport::TestCase
  URL_ENV = {
    "DATABASE_URL" => "postgres://primary_user:secret@127.0.0.1/mitsubachi_production",
    "DATABASE_CACHE_URL" => "postgres://cache_user:secret@127.0.0.1/mitsubachi_production_cache",
    "DATABASE_QUEUE_URL" => "postgres://queue_user:secret@127.0.0.1/mitsubachi_production_queue",
    "DATABASE_CABLE_URL" => "postgres://cable_user:secret@127.0.0.1/mitsubachi_production_cable"
  }.freeze

  test "production databases use explicit url environment variables" do
    with_database_url_env(URL_ENV) do
      ENV["RAILS_ENV"] = "production"
      production = database_configuration.fetch("production")

      assert_equal URL_ENV["DATABASE_URL"], production.dig("primary", "url")
      assert_equal URL_ENV["DATABASE_CACHE_URL"], production.dig("cache", "url")
      assert_equal URL_ENV["DATABASE_QUEUE_URL"], production.dig("queue", "url")
      assert_equal URL_ENV["DATABASE_CABLE_URL"], production.dig("cable", "url")
      assert_equal "db/cache_migrate", production.dig("cache", "migrations_paths")
      assert_equal "db/queue_migrate", production.dig("queue", "migrations_paths")
      assert_equal "db/cable_migrate", production.dig("cable", "migrations_paths")

      production.each_value do |config|
        assert_nil config["username"]
        assert_nil config["database"]
      end
    end
  end

  test "production configuration fails when a secondary database url is missing" do
    with_database_url_env("DATABASE_URL" => URL_ENV.fetch("DATABASE_URL")) do
      ENV["RAILS_ENV"] = "production"
      error = assert_raises(KeyError) { database_configuration }

      assert_match "DATABASE_CACHE_URL", error.message
    end
  end

  test "development and test database names stay unchanged" do
    with_database_url_env(URL_ENV) do
      configuration = database_configuration

      assert_equal "mitsubachi_ruby_development", configuration.dig("development", "database")
      assert_equal "mitsubachi_ruby_test", configuration.dig("test", "database")
    end
  end

  private

  def database_configuration
    rendered = ERB.new(Rails.root.join("config/database.yml").read).result

    YAML.safe_load(rendered, aliases: true)
  end

  def with_database_url_env(values)
    original = (URL_ENV.keys + [ "RAILS_ENV" ]).to_h { |key| [ key, ENV[key] ] }

    URL_ENV.each_key { |key| ENV.delete(key) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
