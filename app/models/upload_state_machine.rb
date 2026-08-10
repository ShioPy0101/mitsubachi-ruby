module UploadStateMachine
  STATES = %i[
    received
    staging
    staged
    validating
    ready
    committing
    committed
    publishing
    completed
    blocked
    failed
    canceled
  ].freeze

  BLOCK_REASONS = %i[
    active_content_duplicate
    trash_content_duplicate
    duplicate_name
    invalid_parent
    replace_target_changed
  ].freeze

  FAILURE_CODES = %i[
    staging_failed
    validation_failed
    commit_failed
    publish_failed
  ].freeze

  EVENTS = %i[
    start_staging
    staging_succeeded
    staging_failed
    start_validation
    validation_succeeded
    validation_blocked
    validation_failed
    start_commit
    commit_succeeded
    commit_blocked
    commit_failed
    start_publish
    publish_succeeded
    publish_failed
    cancel
    retry_publish
    restart_upload
  ].freeze

  SPEC = {
    received: {
      start_staging: { to: :staging },
      cancel: { to: :canceled }
    },
    staging: {
      staging_succeeded: {
        to: :staged,
        requires: %i[staging_file_complete checksum_present],
        invariants: %i[drive_item_absent final_file_absent]
      },
      staging_failed: {
        to: :failed,
        failure_code: :staging_failed,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      },
      cancel: {
        to: :canceled,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      }
    },
    staged: {
      start_validation: { to: :validating },
      restart_upload: {
        to: :received,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      },
      cancel: {
        to: :canceled,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      }
    },
    validating: {
      validation_succeeded: { to: :ready },
      validation_blocked: {
        to: :blocked,
        reasons: %i[active_content_duplicate trash_content_duplicate duplicate_name invalid_parent],
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      },
      validation_failed: {
        to: :failed,
        failure_code: :validation_failed,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      },
      cancel: {
        to: :canceled,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      }
    },
    ready: {
      start_commit: { to: :committing },
      validation_blocked: {
        to: :blocked,
        reasons: %i[active_content_duplicate duplicate_name invalid_parent],
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      },
      commit_failed: {
        to: :failed,
        failure_code: :commit_failed,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      },
      restart_upload: {
        to: :received,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      },
      cancel: {
        to: :canceled,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      }
    },
    committing: {
      commit_succeeded: {
        to: :committed,
        requires: %i[drive_item_present staging_file_complete],
        recovery: :ensure_published
      },
      commit_blocked: {
        to: :blocked,
        reasons: %i[active_content_duplicate duplicate_name invalid_parent replace_target_changed],
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      },
      commit_failed: {
        to: :failed,
        failure_code: :commit_failed,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent },
        retry: :restart_upload
      }
    },
    committed: {
      start_publish: {
        to: :publishing,
        recovery: :verify_publish
      },
      retry_publish: {
        to: :publishing,
        recovery: :verify_publish,
        artifacts: { staging_file: :keep, drive_item: :keep, final_file: :unknown }
      },
      publish_failed: {
        to: :failed,
        failure_code: :publish_failed,
        compensation: :compensate_db,
        artifacts: { staging_file: :discard, drive_item: :discard, final_file: :discard },
        retry: :restart_upload
      }
    },
    publishing: {
      publish_succeeded: {
        to: :completed,
        requires: %i[drive_item_present final_file_present staging_file_absent]
      },
      publish_failed: {
        to: :failed,
        failure_code: :publish_failed,
        compensation: :compensate_db,
        artifacts: { staging_file: :discard, drive_item: :discard, final_file: :discard },
        retry: :restart_upload
      },
      retry_publish: {
        to: :publishing,
        recovery: :verify_publish,
        artifacts: { staging_file: :keep, drive_item: :keep, final_file: :unknown }
      }
    },
    blocked: {
      restart_upload: {
        to: :received,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      },
      cancel: {
        to: :canceled,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent, final_file: :absent }
      }
    },
    failed: {
      restart_upload: {
        to: :received,
        compensation: :cleanup_staging,
        artifacts: { staging_file: :discard, drive_item: :absent_or_compensated, final_file: :absent_or_compensated }
      }
    }
  }.freeze

  TERMINAL_STATES = %i[completed canceled].freeze

  CONFLICTS = {
    active_content: {
      block_reason: :active_content_duplicate,
      status: :conflict,
      code: :active_content_duplicate
    },
    trash_content: {
      block_reason: :trash_content_duplicate,
      status: :conflict,
      code: :trash_content_duplicate
    },
    active_name: {
      block_reason: :duplicate_name,
      status: :conflict,
      code: :duplicate_name
    },
    invalid_parent: {
      block_reason: :invalid_parent,
      status: :not_found,
      code: :invalid_parent
    }
  }.freeze

  CONSTRAINT_CONFLICTS = {
    "index_active_drive_items_on_org_parent_name_extension" => :active_name
  }.freeze

  FRONTEND_STATE_PROJECTION = {
    received: { status: :queued },
    staging: { status: :uploading },
    staged: { status: :processing, phase: :staged },
    validating: { status: :processing, phase: :validating },
    ready: { status: :processing, phase: :ready },
    committing: { status: :processing, phase: :committing },
    committed: { status: :processing, phase: :committed },
    publishing: { status: :processing, phase: :publishing },
    completed: { status: :completed },
    blocked: { status: :conflict },
    failed: { status: :failed },
    canceled: { status: :canceled }
  }.freeze

  # DriveItem は親/置換対象/復元対象/descendant という意味役割で順序を分けると
  # service 間で容易に lock inversion が生まれる。UploadAttempt を使う upload 系だけ
  # 先に attempt row を取り、その後の DriveItem row は役割に関係なく id 昇順で固定する。
  GLOBAL_LOCK_ORDER = %i[
    upload_attempt
    drive_item_id_asc
  ].freeze

  LOCK_MATRIX = [
    {
      operation: :upload,
      resources: %i[upload_attempt parent_directory],
      lock_order: "upload_attempt -> DriveItem ids ascending",
      validation_after_lock: "parent is active directory; active name/hash prechecks are repeated",
      concurrent_result: "DB unique constraint or locked parent converts race into domain conflict"
    },
    {
      operation: :trash,
      resources: %i[drive_item_tree],
      lock_order: "drive_item ids ascending",
      validation_after_lock: "already deleted/purged nodes are skipped",
      concurrent_result: "newly committed child is trashed with parent; waiting upload sees invalid parent"
    },
    {
      operation: :restore,
      resources: %i[restore_target restore_items],
      lock_order: "DriveItem ids ascending",
      validation_after_lock: "DB unique constraints protect active name/hash",
      concurrent_result: "restore conflict response"
    },
    {
      operation: :replace,
      resources: %i[upload_attempt parent_directory replace_target],
      lock_order: "upload_attempt -> DriveItem ids ascending",
      validation_after_lock: "replace target is still trashed and hash-matching",
      concurrent_result: "domain conflict or invalid parent"
    },
    {
      operation: :directory_create,
      resources: %i[upload_attempt parent_directory],
      lock_order: "upload_attempt -> DriveItem ids ascending",
      validation_after_lock: "parent active and name free",
      concurrent_result: "duplicate_name conflict"
    }
  ].freeze

  COMPENSATION_MATRIX = SPEC.each_with_object({}) do |(state, events), matrix|
    events.each do |event, definition|
      next unless definition[:compensation]

      matrix[state] ||= []
      matrix[state] << {
        event:,
        to: definition.fetch(:to),
        compensation: definition.fetch(:compensation),
        artifacts: definition.fetch(:artifacts, {}),
        retry: definition[:retry]
      }
    end
  end.freeze

  # Crash recovery は「観測された状態 + DB/FS の実体」から、実際に SPEC 上で許可された
  # event だけを選ぶ。in-progress 状態は同じ状態へ盲目的に retry せず、DriveItem と
  # staging/final の有無を見て安全な checkpoint へ寄せる。
  CRASH_MATRIX = [
    {
      point: :before_staging_write,
      observed_state: :received,
      filesystem: :no_staging_no_final,
      db: :attempt_only,
      event: :start_staging,
      recovery_action: :resume_staging,
      resulting_state: :staging
    },
    {
      point: :during_staging_write,
      observed_state: :staging,
      filesystem: :partial_staging_no_final,
      db: :drive_item_absent,
      event: :staging_failed,
      recovery_action: :cleanup_staging,
      resulting_state: :failed
    },
    {
      point: :after_staging_complete,
      observed_state: :staged,
      filesystem: :staging_complete_no_final,
      db: :drive_item_absent,
      event: :start_validation,
      recovery_action: :resume_validation,
      resulting_state: :validating
    },
    {
      point: :during_duplicate_validation,
      observed_state: :validating,
      filesystem: :staging_complete_no_final,
      db: :drive_item_absent,
      event: :validation_failed,
      recovery_action: :cleanup_and_restart,
      resulting_state: :failed
    },
    {
      point: :before_db_commit,
      observed_state: :ready,
      filesystem: :staging_complete_no_final,
      db: :drive_item_absent,
      event: :start_commit,
      recovery_action: :resume_commit,
      resulting_state: :committing
    },
    {
      point: :during_db_commit_without_drive_item,
      observed_state: :committing,
      filesystem: :staging_complete_no_final,
      db: :drive_item_absent,
      event: :commit_failed,
      recovery_action: :cleanup_staging,
      resulting_state: :failed
    },
    {
      point: :during_db_commit_with_drive_item,
      observed_state: :committing,
      filesystem: :staging_complete_no_final,
      db: :drive_item_present,
      event: :commit_succeeded,
      recovery_action: :advance_to_committed,
      resulting_state: :committed
    },
    {
      point: :after_db_commit_before_publish,
      observed_state: :committed,
      filesystem: :staging_complete_no_final,
      db: :drive_item_present,
      event: :start_publish,
      recovery_action: :publish_staging,
      resulting_state: :completed
    },
    {
      point: :during_publish_staging_only,
      observed_state: :publishing,
      filesystem: :staging_complete_no_final,
      db: :drive_item_present,
      event: :retry_publish,
      recovery_action: :publish_staging,
      resulting_state: :completed
    },
    {
      point: :during_publish_final_only,
      observed_state: :publishing,
      filesystem: :no_staging_final_present,
      db: :drive_item_present,
      event: :publish_succeeded,
      recovery_action: :mark_completed,
      resulting_state: :completed
    },
    {
      point: :during_publish_both_files,
      observed_state: :publishing,
      filesystem: :staging_and_final_present,
      db: :drive_item_present,
      event: :publish_succeeded,
      recovery_action: :cleanup_staging_and_mark_completed,
      resulting_state: :completed
    },
    {
      point: :during_publish_no_files,
      observed_state: :publishing,
      filesystem: :no_staging_no_final,
      db: :drive_item_present,
      event: :publish_failed,
      recovery_action: :compensate_db,
      resulting_state: :failed
    },
    {
      point: :after_publish_before_response,
      observed_state: :completed,
      filesystem: :no_staging_final_present,
      db: :drive_item_present,
      event: nil,
      recovery_action: :recover_existing_result,
      resulting_state: :completed
    }
  ].freeze

  module_function

  def transition(state, event)
    SPEC.fetch(state.to_sym, {})[event.to_sym]
  end

  def next_state(state, event)
    transition(state, event)&.fetch(:to)
  end

  def allowed_transition?(state, event)
    next_state(state, event).present?
  end

  def events_for(state)
    SPEC.fetch(state.to_sym, {})
  end

  def compensation_entries
    COMPENSATION_MATRIX.values.flatten
  end

  def retry_event_after(definition)
    definition[:retry]
  end

  def conflict_for_constraint(constraint_name)
    CONSTRAINT_CONFLICTS[constraint_name]
  end

  def mermaid_state_diagram
    lines = [ "stateDiagram-v2" ]
    SPEC.each do |state, events|
      events.each { |event, definition| lines << "  #{state} --> #{definition.fetch(:to)}: #{event}" }
    end
    lines.join("\n")
  end
end
