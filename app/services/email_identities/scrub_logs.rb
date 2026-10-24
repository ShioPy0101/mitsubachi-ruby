module EmailIdentities
  # 新しいfilterだけでは既存DBログは消えないため、cutover時に再実行可能な形で洗浄する。
  # 行そのものや監査対象ID・日時は保持し、宛先を含むsnapshot / 自由記述だけを伏せる。
  class ScrubLogs
    def call
      OperationLog.find_each do |log|
        log.update_columns(
          change_set: OperationLogs::Sanitizer.new(log.change_set).call,
          metadata: OperationLogs::Sanitizer.new(log.metadata).call,
          user_agent: Redactor.call(log.user_agent)
        )
      end
      SystemEvent.find_each do |event|
        event.update_columns(
          metadata: SystemEvents::Sanitizer.new(event.metadata).call,
          error_message: event.error_message && Redactor.call(event.error_message)
        )
      end
      DriveItemAccessLog.find_each do |log|
        log.update_columns(metadata: OperationLogs::Sanitizer.new(log.metadata).call, user_agent: Redactor.call(log.user_agent))
      end
    end
  end
end
