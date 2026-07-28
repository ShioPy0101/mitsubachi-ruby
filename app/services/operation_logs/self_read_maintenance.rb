module OperationLogs
  class SelfReadMaintenance
    OPERATION_TYPES = %w[audit_log.index audit_log.show].freeze

    def count
      scope.count
    end

    def purge!(dry_run: true)
      target_count = count
      scope.in_batches.delete_all unless dry_run
      target_count
    end

    private

    def scope
      OperationLog.where(operation_type: OPERATION_TYPES)
    end
  end
end
