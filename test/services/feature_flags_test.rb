require "test_helper"

class FeatureFlagsTest < ActiveSupport::TestCase
  test "unknown features fail closed" do
    assert_raises(KeyError) { FeatureFlags.enabled?(:unknown) }
  end

  test "only explicitly enabled flags are active" do
    original = ENV["FEATURE_DEMO_TENANT"]
    [ nil, "false", "invalid", "true" ].each do |value|
      ENV["FEATURE_DEMO_TENANT"] = value
      assert_equal value == "true", FeatureFlags.enabled?(:demo_tenant)
    end
  ensure
    ENV["FEATURE_DEMO_TENANT"] = original
  end
end
