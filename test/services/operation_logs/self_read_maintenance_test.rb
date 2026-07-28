require "test_helper"

class OperationLogs::SelfReadMaintenanceTest < ActiveSupport::TestCase
  setup do
    @index_log = create_log("audit_log.index")
    @show_log = create_log("audit_log.show")
    @state_change_log = create_log("drive_item.deleted")
    @maintenance = OperationLogs::SelfReadMaintenance.new
  end

  test "counts only operation log self reads" do
    assert_equal 2, @maintenance.count
  end

  test "dry run reports count without deleting logs" do
    assert_no_difference "OperationLog.count" do
      assert_equal 2, @maintenance.purge!
    end
  end

  test "explicit purge deletes only self reads" do
    assert_difference "OperationLog.count", -2 do
      assert_equal 2, @maintenance.purge!(dry_run: false)
    end

    assert_not OperationLog.exists?(@index_log.id)
    assert_not OperationLog.exists?(@show_log.id)
    assert OperationLog.exists?(@state_change_log.id)
  end

  private

  def create_log(operation_type)
    OperationLog.create!(
      operation_type: operation_type,
      actor_kind: "anonymous",
      result: "success",
      occurred_at: Time.current
    )
  end
end
