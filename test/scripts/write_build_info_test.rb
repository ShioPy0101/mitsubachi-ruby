require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

class WriteBuildInfoTest < ActiveSupport::TestCase
  test "build artifact records the supplied commit and build and deployment timestamps" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      script = File.join(root, "bin", "write-build-info")
      FileUtils.cp(Rails.root.join("bin/write-build-info"), script)
      _, error, status = Open3.capture3(
        { "GIT_COMMIT_SHA" => "a" * 40, "BUILD_TIMESTAMP" => "2026-10-21T00:00:00Z", "DEPLOYED_AT" => "2026-10-21T01:00:00Z" },
        RbConfig.ruby, script
      )
      assert status.success?, error
      info = JSON.parse(File.read(File.join(root, "build-info.json")))
      assert_equal "a" * 40, info.fetch("commit")
      assert_equal "2026-10-21T00:00:00Z", info.fetch("built_at")
      assert_equal "2026-10-21T01:00:00Z", info.fetch("deployed_at")
    end
  end
end
