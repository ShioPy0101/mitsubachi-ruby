require "minitest/autorun"
require_relative "../../script/tenant_scope/checker"

class TenantScopeCheckerTest < Minitest::Test
  def test_detects_direct_and_chained_queries
    [
      "DriveItem.find(id)", "::DriveItem.find_by!(id: id)",
      "DriveItem.active.directory.where(id: id).first", "DriveItem.count",
      "DriveItem.all", "DriveItem.not_purged", "DriveItem.custom_scope",
      "DriveItem&.find(id)", "DriveItem.where.not(organization_id: org.id)",
      "DriveItem.where(organization_id: nil)", "DriveItem.where('organization_id = ?', id)",
      "DriveItem.where(metadata: { organization_id: id })",
      "DriveItem.where(organization_id: id).unscoped.find(id)",
      "DriveItem.where(organization_id: id).unscope(:where)",
      "DriveItem.where(organization_id: id).or(DriveItem.all)",
      "DriveItem.find(id).where(organization_id: org.id)",
      "DriveItem.find_by_sql(sql)", "DriveItem.none.unscoped"
    ].each do |source|
      refute_empty check(source).findings, source
    end
  end

  def test_accepts_explicit_filters_associations_and_non_queries
    [
      "DriveItem.where(organization_id: org.id).find(id)",
      "::DriveItem.active.where(organization: current_organization).first",
      "DriveItem.find_by(id: id, organization_id: org.id)",
      "DriveItem.exists?('organization_id' => ids)",
      "DriveItem.where(id: ids).where(organization_id: org.id)",
      "current_user.organization.drive_items.find(id)",
      "organization.drive_items.active.count", "DriveItem.none", "::DriveItem.none.first",
      "DriveItem.new", "DriveItem.valid_storage_key?(key)",
      "DriveItem.storage_root.join(key)", "Other::DriveItem.find(id)",
      "# DriveItem.find(id)", '"DriveItem.find(id)"', "", "# comment only"
    ].each do |source|
      assert_empty check(source).findings, source
      assert_empty check(source).errors, source
    end
  end

  def test_multiline_chain_reports_one_finding_with_location
    source = "# comment\n  ::DriveItem\n    .active\n    .where(id: id).first\n"
    finding = check(source).findings.fetch(0)
    assert_equal 1, check(source).findings.size
    assert_equal [ "example.rb", 2, 3 ], [ finding.path, finding.line, finding.column ]
    assert_equal source.lines.drop(1).join.strip, finding.source
  end

  def test_checks_queries_inside_blocks_and_interpolated_strings
    assert_equal 2, check("DriveItem.all.each { DriveItem.find(id) }").findings.size
    assert_equal 1, check('"#{DriveItem.find(id)}"').findings.size
  end

  def test_invalid_syntax_is_an_error_even_when_ast_is_partially_available
    refute_empty check("DriveItem.find(\n").errors
  end

  def test_bind_parameters_and_overwritten_hash_keys_are_not_tenant_filters
    [
      "DriveItem.where('name = :organization_id', organization_id: name)",
      "DriveItem.where(organization_id: org.id, **filters)",
      "DriveItem.where(organization_id: org.id, organization_id: nil)"
    ].each do |source|
      refute_empty check(source).findings, source
    end
  end

  private

  def check(source)
    TenantScope::Checker.new.check(source, path: "example.rb")
  end
end
