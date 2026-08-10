class UploadAttempt < ApplicationRecord
  class InvalidTransition < StandardError; end

  belongs_to :organization
  belongs_to :user
  belongs_to :drive_item, optional: true

  validates :client_upload_id, presence: true
  validates :state, inclusion: { in: UploadStateMachine::STATES.map(&:to_s) }
  validates :block_reason, inclusion: { in: UploadStateMachine::BLOCK_REASONS.map(&:to_s) }, allow_nil: true
  validates :error_code, inclusion: { in: UploadStateMachine::FAILURE_CODES.map(&:to_s) }, allow_nil: true
  validates :client_upload_id, uniqueness: { scope: :organization_id }

  before_validation :set_initial_state, on: :create

  def state_name
    state.to_sym
  end

  def self.allowed_transition?(state, event)
    UploadStateMachine.allowed_transition?(state, event)
  end

  def self.next_state(state, event)
    UploadStateMachine.next_state(state, event)
  end

  def self.conflict_for_constraint(constraint_name)
    UploadStateMachine.conflict_for_constraint(constraint_name)
  end

  def self.mermaid_state_diagram
    UploadStateMachine.mermaid_state_diagram
  end

  def transition!(event, reason: nil, failure_code: nil, metadata: {})
    event = event.to_sym

    with_lock do
      from_state = state_name
      definition = UploadStateMachine.transition(state_name, event)
      raise InvalidTransition, "#{state} cannot #{event}" if definition.nil?

      validate_transition_reason!(definition, reason)
      self.state = definition.fetch(:to).to_s
      self.block_reason = block_reason_for(definition, reason)
      self.error_code = failure_code_for(definition, failure_code)
      self.last_transition_at = Time.current if has_attribute?(:last_transition_at)
      self.metadata = self.metadata.merge(metadata.stringify_keys) if metadata.present?
      save!
      log_transition!(from_state:, event:, to_state: state_name, reason:, failure_code: error_code)
    end
  end

  def retryable?
    UploadStateMachine.events_for(state_name).keys.grep(/\Aretry_|restart_upload\z/).any?
  end

  def storage_path
    return if storage_key.blank?

    DriveItem.storage_root.join(DriveItem.storage_relative_path_for(storage_key))
  end

  def staging_file_exists?
    staging_path.present? && File.file?(staging_path)
  end

  def final_file_exists?
    storage_path.present? && File.file?(storage_path)
  end

  def invariant_errors
    case state_name
    when :staged
      invariant_presence_errors(checksum: file_hash, staging: staging_file_exists?, drive_item_absent: drive_item_id.nil?)
    when :committed
      invariant_presence_errors(drive_item: drive_item_id, staging: staging_file_exists?)
    when :completed
      invariant_presence_errors(drive_item: drive_item_id, final: final_file_exists?, staging_absent: !staging_file_exists?)
    else
      []
    end
  end

  private

  def validate_transition_reason!(definition, reason)
    return unless definition[:to] == :blocked

    normalized = reason&.to_sym
    unless normalized && definition.fetch(:reasons).include?(normalized)
      raise InvalidTransition, "blocked transition requires one of #{definition.fetch(:reasons).join(", ")}"
    end
  end

  def block_reason_for(definition, reason)
    return reason.to_s if definition[:to] == :blocked
    nil unless definition[:to] == :blocked
  end

  def failure_code_for(definition, failure_code)
    code = failure_code || definition[:failure_code]
    return nil if code.blank?

    code.to_s
  end

  def set_initial_state
    self.state ||= "received"
  end

  def invariant_presence_errors(checks)
    checks.filter_map do |name, value|
      value.present? ? nil : name
    end
  end

  def log_transition!(from_state:, event:, to_state:, reason:, failure_code:)
    Rails.logger.info({
      event: "upload_attempt.transition",
      upload_attempt_id: id,
      organization_id: organization_id,
      user_id: user_id,
      from_state:,
      transition_event: event,
      to_state:,
      block_reason: reason,
      failure_code:
    }.to_json)
  end
end
