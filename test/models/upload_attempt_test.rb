require "test_helper"
require "set"
require "fileutils"

class UploadAttemptTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @organization = organizations(:one)
    @user = users(:one)
  end

  teardown do
    UploadAttempt.where(organization: @organization).delete_all if defined?(@organization)
  end

  test "state machine specification references only declared states events reasons and codes" do
    referenced_states = UploadStateMachine::SPEC.flat_map do |state, events|
      [ state, *events.values.map { |definition| definition.fetch(:to) } ]
    end.to_set
    referenced_events = UploadStateMachine::SPEC.values.flat_map(&:keys).to_set
    referenced_reasons = UploadStateMachine::SPEC.values.flat_map do |events|
      events.values.flat_map { |definition| definition.fetch(:reasons, []) }
    end.to_set
    referenced_failure_codes = UploadStateMachine::SPEC.values.flat_map do |events|
      events.values.filter_map { |definition| definition[:failure_code] }
    end.to_set

    assert_empty referenced_states - UploadStateMachine::STATES.to_set
    assert_empty referenced_events - UploadStateMachine::EVENTS.to_set
    assert_empty UploadStateMachine::EVENTS.to_set - referenced_events
    assert_empty referenced_reasons - UploadStateMachine::BLOCK_REASONS.to_set
    assert_empty referenced_failure_codes - UploadStateMachine::FAILURE_CODES.to_set
    assert_empty UploadStateMachine::BLOCK_REASONS.to_set - referenced_reasons - UploadStateMachine::CONFLICTS.values.map { |value| value.fetch(:block_reason) }.to_set
    assert_empty UploadStateMachine::FAILURE_CODES.to_set - referenced_failure_codes
  end

  test "all allowed transitions move through declared events" do
    UploadStateMachine::SPEC.each do |state, events|
      events.each do |event, definition|
        attempt = build_attempt(state)
        reason = definition.fetch(:reasons, []).first

        attempt.transition!(event, reason:)

        assert_equal definition.fetch(:to), attempt.state_name, "#{state} --#{event}--> #{definition.fetch(:to)}"
        if reason
          assert_equal reason.to_s, attempt.block_reason
        else
          assert_nil attempt.block_reason
        end
        if definition[:failure_code]
          assert_equal definition[:failure_code].to_s, attempt.error_code
        else
          assert_nil attempt.error_code
        end
      end
    end
  end

  test "all disallowed transitions are rejected" do
    UploadStateMachine::STATES.each do |state|
      UploadStateMachine::EVENTS.each do |event|
        next if UploadStateMachine.allowed_transition?(state, event)

        attempt = build_attempt(state)

        assert_raises(UploadAttempt::InvalidTransition, "#{state} must not accept #{event}") do
          attempt.transition!(event)
        end
      end
    end
  end

  test "blocked transitions require explicit known reason" do
    attempt = build_attempt(:validating)

    assert_raises(UploadAttempt::InvalidTransition) do
      attempt.transition!(:validation_blocked)
    end

    attempt.transition!(:validation_blocked, reason: :duplicate_name)
    assert_equal "blocked", attempt.state
    assert_equal "duplicate_name", attempt.block_reason
  end

  test "terminal states do not allow transitions" do
    UploadStateMachine::TERMINAL_STATES.each do |state|
      assert_empty UploadStateMachine.events_for(state)
    end
  end

  test "conflict and constraint mappings are complete" do
    assert_equal :active_name, UploadAttempt.conflict_for_constraint("index_active_drive_items_on_org_parent_name_extension")
    assert_nil UploadAttempt.conflict_for_constraint("unknown_unique_constraint")

    UploadStateMachine::CONFLICTS.each_value do |definition|
      assert_includes UploadStateMachine::BLOCK_REASONS, definition.fetch(:block_reason)
      assert_includes %i[conflict not_found unprocessable_content], definition.fetch(:status)
      assert definition.fetch(:code).present?
    end
  end

  test "frontend projection recovery compensation and crash matrices cover known states" do
    assert_equal UploadStateMachine::STATES.to_set, UploadStateMachine::FRONTEND_STATE_PROJECTION.keys.to_set
    assert_empty UploadStateMachine::COMPENSATION_MATRIX.keys.to_set - UploadStateMachine::STATES.to_set
    assert UploadStateMachine::COMPENSATION_MATRIX.key?(:committed)
    assert UploadStateMachine::CRASH_MATRIX.any? { |rule| rule[:point] == :after_db_commit_before_publish }
    assert_includes UploadAttempt.mermaid_state_diagram, "received --> staging: start_staging"
  end

  test "compensation rules do not advertise retry without preserved artifacts" do
    UploadStateMachine.compensation_entries.each do |entry|
      next unless entry[:retry]

      if entry.dig(:artifacts, :staging_file) == :discard
        assert_equal :restart_upload, entry[:retry], "#{entry[:event]} discards staging and cannot retry from a later checkpoint"
      end
      assert UploadStateMachine.allowed_transition?(entry[:to], entry[:retry]), "#{entry[:to]} must allow #{entry[:retry]}"
    end
  end

  test "crash recovery rules use executable state machine events" do
    UploadStateMachine::CRASH_MATRIX.each do |rule|
      next if rule[:event].nil?

      assert_includes UploadStateMachine::STATES, rule.fetch(:observed_state)
      assert_includes UploadStateMachine::STATES, rule.fetch(:resulting_state)
      assert UploadStateMachine.allowed_transition?(rule.fetch(:observed_state), rule.fetch(:event)),
             "#{rule.fetch(:point)} must use an event allowed from #{rule.fetch(:observed_state)}"
      direct_state = UploadStateMachine.next_state(rule.fetch(:observed_state), rule.fetch(:event))
      if rule.fetch(:recovery_action) == :publish_staging
        assert_equal :publishing, direct_state
        assert_equal :completed, rule.fetch(:resulting_state)
      else
        assert_equal direct_state, rule.fetch(:resulting_state)
      end
    end
  end

  test "same attempt cannot start commit twice concurrently" do
    attempt = build_attempt(:ready)
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          attempt.reload.transition!(:start_commit)
          results << :committing
        rescue UploadAttempt::InvalidTransition => error
          results << error
        end
      end
    end

    2.times { start << true }
    threads.each(&:join)
    values = 2.times.map { results.pop }

    assert_equal 1, values.count(:committing)
    assert_equal 1, values.count { |value| value.is_a?(UploadAttempt::InvalidTransition) }
    assert_equal "committing", attempt.reload.state
  end

  test "state invariants inspect database and filesystem artifacts" do
    path = DriveItem.storage_root.join("drive_items", ".invariant-#{SecureRandom.hex(8)}.tmp")
    FileUtils.mkdir_p(path.dirname)
    File.write(path, "body")
    attempt = build_attempt(:staged)
    attempt.update!(file_hash: Digest::SHA256.hexdigest("body"), staging_path: path.to_s, storage_key: "invariant-#{SecureRandom.hex(8)}.txt")

    assert_empty attempt.invariant_errors

    FileUtils.rm_f(path)
    assert_includes attempt.invariant_errors, :staging
  ensure
    FileUtils.rm_f(path) if path
  end

  test "recovery publishes committed staging file and reaches completed" do
    body = "recoverable body"
    staging_path = DriveItem.storage_root.join("drive_items", ".recovery-#{SecureRandom.hex(8)}.tmp")
    storage_key = "recovery-#{SecureRandom.hex(8)}.txt"
    final_path = DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))
    FileUtils.mkdir_p(staging_path.dirname)
    File.write(staging_path, body)
    drive_item = create_drive_item(storage_key:, body:)
    attempt = build_attempt(:committed)
    attempt.update!(
      drive_item:,
      file_hash: Digest::SHA256.hexdigest(body),
      staging_path: staging_path.to_s,
      storage_key:
    )

    result = UploadAttempts::RecoveryService.new(upload_attempt: attempt).call

    assert_equal :completed, result.state
    assert_equal "completed", attempt.reload.state
    assert File.file?(final_path)
    refute File.exist?(staging_path)
    assert_empty attempt.invariant_errors
  ensure
    FileUtils.rm_f(staging_path) if staging_path
    FileUtils.rm_f(final_path) if final_path
  end

  test "upload workflow state is only mutated by UploadAttempt transition implementation" do
    offenders = Dir[Rails.root.join("app/**/*.rb")]
      .reject { |path| path.end_with?("app/models/upload_attempt.rb") }
      .select { |path| File.read(path).match?(/\.state\s*=/) }

    assert_empty offenders
  end

  private

  def build_attempt(state)
    UploadAttempt.create!(
      organization: @organization,
      user: @user,
      client_upload_id: SecureRandom.uuid,
      state: state.to_s
    )
  end

  def create_drive_item(storage_key:, body:)
    DriveItem.create!(
      organization: @organization,
      owner_user: @user,
      name: "attempt-recovery-#{SecureRandom.hex(4)}",
      extension: "txt",
      item_type: :file,
      storage_key: storage_key,
      blob_path: DriveItem.storage_relative_path_for(storage_key),
      file_hash: Digest::SHA256.hexdigest(body),
      file_size: body.bytesize,
      content_type: "text/plain"
    )
  end
end
