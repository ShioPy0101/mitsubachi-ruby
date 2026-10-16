require "test_helper"

class UploadResolutionPolicyTest < ActiveSupport::TestCase
  test "resolution matrix accepts only declared category resolution pairs" do
    UploadResolutionPolicy::CATEGORIES.each do |category|
      UploadResolutionPolicy::RESOLUTIONS.each do |resolution|
        policy_json = { category:, resolution:, scope: "batch" }.to_json
        allowed = UploadResolutionPolicy::CONFLICT_MATRIX.fetch(category).fetch(:allowed_resolutions).include?(resolution)

        if allowed
          policy = UploadResolutionPolicy.from_params(ActionController::Parameters.new(upload_policy: policy_json))
          assert_equal resolution, policy.resolution_for(category, item_key: "task-1")
        else
          assert_raises(UploadResolutionPolicy::InvalidPolicy) do
            UploadResolutionPolicy.from_params(ActionController::Parameters.new(upload_policy: policy_json))
          end
        end
      end
    end
  end

  test "item rule overrides batch rule and batch rule overrides default" do
    policy = UploadResolutionPolicy.from_params(
      ActionController::Parameters.new(
        upload_policy: [
          { category: "duplicate_name", resolution: "skip", scope: "batch" },
          { category: "duplicate_name", resolution: "auto_rename", scope: "item", itemKey: "task-1" }
        ].to_json
      )
    )

    assert_equal :auto_rename, policy.resolution_for(:duplicate_name, item_key: "task-1")
    assert_equal :skip, policy.resolution_for(:duplicate_name, item_key: "task-2")
    assert_nil policy.resolution_for(:invalid_parent, item_key: "task-1")
  end

  test "explicit item policy requires item key" do
    assert_raises(UploadResolutionPolicy::InvalidPolicy) do
      UploadResolutionPolicy.from_params(
        ActionController::Parameters.new(
          upload_policy: { category: "duplicate_name", resolution: "auto_rename", scope: "item" }.to_json
        )
      )
    end
  end

  test "invalid explicit policy is not silently ignored" do
    invalid_inputs = [
      "{",
      { category: "unknown", resolution: "skip", scope: "batch" }.to_json,
      { category: "duplicate_name", resolution: "restore", scope: "batch" }.to_json,
      { category: "duplicate_name", resolution: "aut_rename", scope: "batch" }.to_json,
      { category: "duplicate_name", resolution: "auto_rename", scope: "global" }.to_json,
      [
        { category: "duplicate_name", resolution: "skip", scope: "batch" },
        { category: "duplicate_name", resolution: "auto_rename", scope: "batch" }
      ].to_json
    ]

    invalid_inputs.each do |upload_policy|
      assert_raises(UploadResolutionPolicy::InvalidPolicy) do
        UploadResolutionPolicy.from_params(ActionController::Parameters.new(upload_policy:))
      end
    end
  end

  test "legacy name field normalizes to item-scoped rule and content field is ignored" do
    policy = UploadResolutionPolicy.from_params(
      ActionController::Parameters.new(
        allow_duplicate_content: "true",
        name_conflict_action: "auto_rename"
      ),
      default_item_key: "task-1"
    )

    assert_equal :auto_rename, policy.resolution_for(:duplicate_name, item_key: "task-1")
    assert_equal 1, policy.rules.size
  end

  test "deprecated content duplicate policies are ignored" do
    policy = UploadResolutionPolicy.from_params(
      ActionController::Parameters.new(
        upload_policy: [
          { category: "active_content_duplicate", resolution: "upload_anyway", scope: "batch" },
          { category: "trash_content_duplicate", resolution: "restore", scope: "batch" }
        ].to_json
      )
    )

    assert_empty policy.rules
  end
end
