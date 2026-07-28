class LogRetentionJob < ApplicationJob
  queue_as :maintenance

  def perform
    Logs::Retention.new.call
  end
end
