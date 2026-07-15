require "test_helper"

class ProductionDatabaseConfigValidatorTest < ActiveSupport::TestCase
  def setup
    @env = {
      "DATABASE_URL" => "postgresql://mitsubachi:secret@127.0.0.1:5432/mitsubachi_production",
      "DATABASE_CACHE_URL" => "postgresql://mitsubachi:secret@127.0.0.1:5432/mitsubachi_production_cache",
      "DATABASE_QUEUE_URL" => "postgresql://mitsubachi:secret@127.0.0.1:5432/mitsubachi_production_queue",
      "DATABASE_CABLE_URL" => "postgresql://mitsubachi:secret@127.0.0.1:5432/mitsubachi_production_cable"
    }
  end

  test "accepts all production database urls when they use the same role and tcp host" do
    output = StringIO.new

    assert ProductionDatabaseConfigValidator.validate!(env: @env, out: output)
    assert_includes output.string, "primary env=DATABASE_URL host=127.0.0.1 port=5432 database=mitsubachi_production username=mitsubachi password_set=yes"
    assert_not_includes output.string, "secret"
    assert_not_includes output.string, "postgresql://"
  end

  test "rejects the regression where only primary url is configured" do
    env = @env.slice("DATABASE_URL")

    error = assert_raises ProductionDatabaseConfigValidator::Error do
      ProductionDatabaseConfigValidator.validate!(env:, out: StringIO.new)
    end

    assert_includes error.message, "cache: DATABASE_CACHE_URL is not set"
    assert_includes error.message, "queue: DATABASE_QUEUE_URL is not set"
    assert_includes error.message, "cable: DATABASE_CABLE_URL is not set"
  end

  test "rejects urls that would fall back to unix socket connections" do
    @env["DATABASE_QUEUE_URL"] = "postgresql://mitsubachi:secret@/mitsubachi_production_queue"

    error = assert_raises ProductionDatabaseConfigValidator::Error do
      ProductionDatabaseConfigValidator.validate!(env: @env, out: StringIO.new)
    end

    assert_includes error.message, "queue: host must be 127.0.0.1"
  end

  test "rejects mismatched database role" do
    @env["DATABASE_CABLE_URL"] = "postgresql://mitsubachi_ruby:secret@127.0.0.1:5432/mitsubachi_production_cable"

    error = assert_raises ProductionDatabaseConfigValidator::Error do
      ProductionDatabaseConfigValidator.validate!(env: @env, out: StringIO.new)
    end

    assert_includes error.message, "cable: username must be mitsubachi"
  end

  test "rejects unexpected database names" do
    @env["DATABASE_CACHE_URL"] = "postgresql://mitsubachi:secret@127.0.0.1:5432/mitsubachi_ruby_production_cache"

    error = assert_raises ProductionDatabaseConfigValidator::Error do
      ProductionDatabaseConfigValidator.validate!(env: @env, out: StringIO.new)
    end

    assert_includes error.message, "cache: database must be mitsubachi_production_cache"
  end
end
