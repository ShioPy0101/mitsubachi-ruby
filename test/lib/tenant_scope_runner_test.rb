require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../script/tenant_scope/runner"

class TenantScopeRunnerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("tenant-scope")
    FileUtils.mkdir_p(File.join(@root, "app/services"))
    FileUtils.mkdir_p(File.join(@root, "lib/tasks"))
    FileUtils.mkdir_p(File.join(@root, "config"))
    write("config/tenant_scope_exceptions.yml", [].to_yaml)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_scans_all_files_and_reports_locations
    write("app/services/a file.rb", "DriveItem.find(id)")
    write("lib/tasks/count.rake", "DriveItem.count")
    status, output = run_check
    assert_equal 1, status
    assert_includes output, "app/services/a file.rb:1:1:"
    assert_includes output, "lib/tasks/count.rake:1:1:"
    assert_includes output, "2 violations"
  end

  def test_empty_and_comment_only_files_pass
    write("app/services/empty.rb", "")
    write("app/services/comment.rb", "# DriveItem.find(id)")
    assert_equal 0, run_check.first
  end

  def test_exact_exception_survives_line_changes_but_does_not_hide_duplicate_calls
    except_query("DriveItem.all")
    write("app/services/query.rb", "\nDriveItem.all")
    assert_equal 0, run_check.first
    write("app/services/query.rb", "DriveItem.all\nDriveItem.all")
    status, output = run_check
    assert_equal 1, status
    assert_includes output, "1 violations"
  end

  def test_changed_query_and_stale_exception_fail
    except_query("DriveItem.all")
    write("app/services/query.rb", "DriveItem.find(id)")
    status, output = run_check
    assert_equal 1, status
    assert_includes output, "1 violations, 1 unused exceptions"
    write("app/services/query.rb", "organization.drive_items.all")
    assert_equal 1, run_check.first
  end

  def test_syntax_errors_missing_files_and_invalid_configuration_fail_closed
    write("app/services/query.rb", "DriveItem.find(")
    assert_equal 2, run_check.first
    write("app/services/query.rb", "")
    write("config/tenant_scope_exceptions.yml", "- path: example.rb")
    assert_equal 2, run_check.first
    write("config/tenant_scope_exceptions.yml", "[")
    assert_equal 2, run_check.first
    File.delete(File.join(@root, "config/tenant_scope_exceptions.yml"))
    assert_equal 2, run_check.first
  end

  def test_duplicate_exceptions_and_empty_scan_fail
    entry = { "path" => "app/services/query.rb", "source" => "DriveItem.all", "reason" => "test" }
    write("config/tenant_scope_exceptions.yml", [ entry, entry ].to_yaml)
    assert_equal 2, run_check.first
    write("config/tenant_scope_exceptions.yml", [].to_yaml)
    assert_equal 2, run_check.first
  end

  private

  def except_query(source)
    write("config/tenant_scope_exceptions.yml", [
      { "path" => "app/services/query.rb", "source" => source, "reason" => "system admin only" }
    ].to_yaml)
  end

  def write(path, source)
    File.write(File.join(@root, path), source)
  end

  def run_check
    output = StringIO.new
    [ TenantScope::Runner.new(root: @root, output: output).run, output.string ]
  end
end
