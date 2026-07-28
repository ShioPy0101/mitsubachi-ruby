namespace :logs do
  desc "Backfill renamed OperationLog fields and actor information in bounded batches"
  task backfill_operation_logs: :environment do
    result = LogMigrations::OperationLogBackfill.new(
      batch_size: ENV.fetch("BATCH_SIZE", LogMigrations::OperationLogBackfill::DEFAULT_BATCH_SIZE).to_i
    ).call
    puts "processed=#{result.processed_count} updated=#{result.updated_count}"
  end

  desc "Move historical file access operations into DriveItemAccessLog without duplicates"
  task backfill_file_access_logs: :environment do
    result = LogMigrations::FileAccessBackfill.new(
      batch_size: ENV.fetch("BATCH_SIZE", LogMigrations::FileAccessBackfill::DEFAULT_BATCH_SIZE).to_i
    ).call
    puts "processed=#{result.processed_count} inserted=#{result.inserted_count} " \
         "deduplicated=#{result.deduplicated_count} removed=#{result.removed_count}"
  end

  desc "Backfill only legacy administrator records missing from OperationLog"
  task backfill_legacy_admin_logs: :environment do
    result = LogMigrations::LegacyAdminLogBackfill.new(
      batch_size: ENV.fetch("BATCH_SIZE", LogMigrations::LegacyAdminLogBackfill::DEFAULT_BATCH_SIZE).to_i
    ).call
    puts "processed=#{result.processed_count} inserted=#{result.inserted_count} " \
         "deduplicated=#{result.deduplicated_count}"
  end
end
