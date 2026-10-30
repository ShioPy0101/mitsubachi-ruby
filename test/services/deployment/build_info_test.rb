require "test_helper"
require "tempfile"

class Deployment::BuildInfoTest < ActiveSupport::TestCase
  test "reads immutable build and production deployment metadata without secrets" do
    Tempfile.create("build-info") do |file|
      file.write({ commit: "a" * 40, built_at: "2026-10-21T00:00:00Z", deployed_at: "2026-10-21T01:00:00Z", secret: "hidden" }.to_json)
      file.flush
      info = Deployment::BuildInfo.read(path: Pathname(file.path), env: {})
      assert_equal "a" * 40, info[:commit]
      assert_equal "2026-10-21T00:00:00Z", info[:built_at]
      assert_equal "2026-10-21T01:00:00Z", info[:deployed_at]
      assert_not info.key?(:secret)
    end
  end

  test "missing metadata remains unknown instead of inventing a build time" do
    info = Deployment::BuildInfo.read(path: Rails.root.join("tmp/missing-build-info.json"), env: {})
    assert_nil info[:commit]
    assert_nil info[:built_at]
    assert_nil info[:deployed_at]
  end
end
