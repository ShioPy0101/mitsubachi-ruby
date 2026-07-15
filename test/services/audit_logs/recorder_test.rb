require "test_helper"

class AuditLogs::RecorderTest < ActiveSupport::TestCase
  setup do
    @organization = organizations(:one)
    @user = users(:one)
    @drive_item = drive_items(:child_file)
    @request = Struct.new(:remote_ip, :user_agent, :request_id).new("203.0.113.10", "RecorderTest/1.0", "req-service")
  end

  test "5分以内の stream ログは重複作成しない" do
    assert_difference "DriveItemAccessLog.count", 1 do
      build_recorder("stream").call
    end

    assert_no_difference "DriveItemAccessLog.count" do
      build_recorder("stream").call
    end
  end

  test "5分を超えると stream ログを再作成する" do
    build_recorder("stream").call
    DriveItemAccessLog.order(:id).last.update_column(:occurred_at, 6.minutes.ago)

    assert_difference "DriveItemAccessLog.count", 1 do
      build_recorder("stream").call
    end
  end

  private

  def build_recorder(action)
    AuditLogs::Recorder.new(
      organization: @organization,
      user: @user,
      drive_item: @drive_item,
      action: action,
      request: @request
    )
  end
end
