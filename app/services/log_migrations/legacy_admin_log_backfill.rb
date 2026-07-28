module LogMigrations
  class LegacyAdminLogBackfill
    DEFAULT_BATCH_SIZE = 500
    Result = Data.define(:processed_count, :inserted_count, :deduplicated_count)

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      counts = { processed: 0, inserted: 0, deduplicated: 0 }

      LegacyAdminAuditLog.in_batches(of: @batch_size) do |relation|
        relation.each { |legacy_log| migrate!(legacy_log, counts) }
      end

      Result.new(counts[:processed], counts[:inserted], counts[:deduplicated])
    end

    private

    def migrate!(legacy_log, counts)
      counts[:processed] += 1
      operation_type = LogMigrations::OperationLogBackfill::OPERATION_TYPE_MAP.fetch(legacy_log.action, legacy_log.action)

      if duplicate?(legacy_log, operation_type)
        counts[:deduplicated] += 1
        return
      end

      OperationLog.create!(
        actor_kind: "user",
        actor_user: legacy_log.actor_user,
        organization: legacy_log.organization,
        operation_type: operation_type,
        result: "success",
        target_type: legacy_log.target_type,
        target_id: legacy_log.target_id,
        change_set: legacy_log.change_set,
        metadata: { legacy_admin_audit_log_id: legacy_log.id },
        ip_address: legacy_log.ip_address,
        user_agent: legacy_log.user_agent,
        request_id: nil,
        occurred_at: legacy_log.created_at,
        created_at: legacy_log.created_at,
        updated_at: legacy_log.updated_at
      )
      counts[:inserted] += 1
    end

    def duplicate?(legacy_log, operation_type)
      return true if OperationLog.where("metadata ->> 'legacy_admin_audit_log_id' = ?", legacy_log.id.to_s).exists?

      OperationLog.where(
        actor_user_id: legacy_log.actor_user_id,
        organization_id: legacy_log.organization_id,
        operation_type: operation_type,
        target_type: legacy_log.target_type,
        target_id: legacy_log.target_id
      ).where(occurred_at: (legacy_log.created_at - 5.seconds)..(legacy_log.created_at + 5.seconds)).exists?
    end
  end
end
