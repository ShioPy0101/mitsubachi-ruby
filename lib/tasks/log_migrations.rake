namespace :logs do
  desc "Backfill renamed OperationLog fields and actor information in bounded batches"
  task backfill_operation_logs: :environment do
    result = LogMigrations::OperationLogBackfill.new(
      batch_size: ENV.fetch("BATCH_SIZE", LogMigrations::OperationLogBackfill::DEFAULT_BATCH_SIZE).to_i
    ).call
    puts "processed=#{result.processed_count} updated=#{result.updated_count}"
  end
end
