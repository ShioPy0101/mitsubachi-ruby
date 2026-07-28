require "test_helper"
require Rails.root.join("db/migrate/20260728100000_finalize_log_storage")

class FinalizeLogStorageTest < ActiveSupport::TestCase
  test "既存操作ログのactor_kindをIDに合わせて制約追加前に正規化する" do
    migration = FinalizeLogStorage.new
    statements = []
    migration.stub(:select_value, 0) do
      migration.stub(:execute, ->(sql) { statements << sql }) do
        migration.send(:normalize_existing_operation_log_actors!)
      end
    end

    sql = statements.fetch(0)
    assert_includes sql, "actor_user_id IS NOT NULL THEN 'user'"
    assert_includes sql, "actor_external_share_id IS NOT NULL THEN 'external_share'"
    assert_includes sql, "ELSE 'anonymous'"
  end

  test "userとexternal shareが同時指定された曖昧な行は自動補正しない" do
    migration = FinalizeLogStorage.new

    migration.stub(:select_value, 1) do
      error = assert_raises(ActiveRecord::MigrationError) do
        migration.send(:normalize_existing_operation_log_actors!)
      end
      assert_includes error.message, "both user and external-share actors"
    end
  end
end
