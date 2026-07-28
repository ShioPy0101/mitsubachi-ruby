class ApplicationJob < ActiveJob::Base
  around_perform do |job, block|
    block.call
  rescue StandardError => error
    SystemEvents::Recorder.record!(
      event_type: "background_job.failed",
      severity: "error",
      source: "worker",
      organization: job_related_organization(job),
      related_user: job_related_user(job),
      job_id: job.job_id,
      error: error,
      metadata: { job_class: job.class.name, queue_name: job.queue_name }
    )
    raise
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private

  def job_related_organization(job)
    argument = job.arguments.find { |value| value.respond_to?(:organization) || value.is_a?(Organization) }
    argument.is_a?(Organization) ? argument : argument&.organization
  end

  def job_related_user(job)
    argument = job.arguments.find { |value| value.is_a?(User) || value.respond_to?(:user) }
    argument.is_a?(User) ? argument : argument&.user
  end
end
