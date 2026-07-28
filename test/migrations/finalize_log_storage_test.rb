require "test_helper"
require Rails.root.join("db/migrate/20260728100000_finalize_log_storage")

class FinalizeLogStorageTest < ActiveSupport::TestCase
  test "既存操作ログのactor_kindをIDに合わせて制約追加前に正規化する" do
    operation_log = create_user_operation_log

    without_actor_constraint(operation_log) do
      OperationLog.where(id: operation_log.id).update_all(actor_kind: "anonymous")
      FinalizeLogStorage.new.send(:normalize_existing_operation_log_actors!)

      assert_equal "user", operation_log.reload.actor_kind
      assert_equal users(:one).id, operation_log.actor_user_id
      assert_nil operation_log.actor_external_share_id
    end
  end

  test "userとexternal shareが同時指定された曖昧な行は自動補正しない" do
    operation_log = create_user_operation_log
    external_share = ExternalShare.create!(
      organization: organizations(:one),
      created_by_user: users(:one),
      name: "migration test share",
      token_digest: SecureRandom.hex(32)
    )

    without_actor_constraint(operation_log) do
      OperationLog.where(id: operation_log.id).update_all(actor_external_share_id: external_share.id)
      error = assert_raises(ActiveRecord::MigrationError) do
        FinalizeLogStorage.new.send(:normalize_existing_operation_log_actors!)
      end
      assert_includes error.message, "both user and external-share actors"
    end
  end

  private

  def create_user_operation_log
    OperationLog.create!(
      actor_kind: "user",
      actor_user: users(:one),
      organization: organizations(:one),
      operation_type: "deployment.migration_test",
      occurred_at: Time.current
    )
  end

  def without_actor_constraint(operation_log)
    connection = ActiveRecord::Base.connection
    connection.remove_check_constraint(:operation_logs, name: "operation_logs_actor_consistency")
    yield
  ensure
    OperationLog.where(id: operation_log.id).delete_all
    connection.add_check_constraint(
      :operation_logs,
      FinalizeLogStorage::ACTOR_CHECK,
      name: "operation_logs_actor_consistency"
    )
  end
end
