require "test_helper"

module DriveItems
  class NameConflictTest < ActiveSupport::TestCase
    setup do
      @organization = organizations(:one)
      @parent = drive_items(:one)
      @file = drive_items(:child_file)
    end

    test "同じorganizationと階層のactive itemだけを競合として扱う" do
      conflict = NameConflict.new(
        organization: @organization,
        parent_id: @parent.id,
        name: @file.name,
        extension: @file.extension
      )

      assert_predicate conflict, :conflict?

      other_organization_conflict = NameConflict.new(
        organization: organizations(:two),
        parent_id: @parent.id,
        name: @file.name,
        extension: @file.extension
      )

      assert_not_predicate other_organization_conflict, :conflict?
    end

    test "削除済みitemの名前は再利用できる" do
      conflict = NameConflict.new(
        organization: @organization,
        parent_id: @parent.id,
        name: drive_items(:deleted_report).name,
        extension: drive_items(:deleted_report).extension
      )

      assert_not_predicate conflict, :conflict?
    end

    test "既存候補を飛ばして利用可能な名前を返す" do
      create_file!(name: "report（1）")
      create_file!(name: "report（2）")

      details = NameConflict.new(
        organization: @organization,
        parent_id: @parent.id,
        name: @file.name,
        extension: @file.extension
      ).details

      assert_equal "report.pdf", details.fetch(:conflicting_name)
      assert_equal "report（3）", details.fetch(:suggested_name)
      assert_equal "report（3）.pdf", details.fetch(:suggested_filename)
    end

    test "更新対象自身は競合と候補生成から除外する" do
      conflict = NameConflict.new(
        organization: @organization,
        parent_id: @parent.id,
        name: @file.name,
        extension: @file.extension,
        excluding_id: @file.id
      )

      assert_not_predicate conflict, :conflict?
      assert_equal "report", conflict.details.fetch(:suggested_name)
    end

    private

    def create_file!(name:)
      @organization.drive_items.create!(
        owner_user: users(:one),
        parent: @parent,
        name: name,
        item_type: :file,
        extension: "pdf",
        storage_key: "#{SecureRandom.uuid}.pdf"
      )
    end
  end
end
