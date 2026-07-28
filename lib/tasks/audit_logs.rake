namespace :audit_logs do
  desc "操作履歴の自己参照ログ件数を表示する"
  task count_self_reads: :environment do
    count = OperationLogs::SelfReadMaintenance.new.count
    puts "audit_log.index/show: #{count}件"
  end

  desc "操作履歴の自己参照ログを削除する（DRY_RUN=falseで実削除）"
  task purge_self_reads: :environment do
    dry_run = ENV.fetch("DRY_RUN", "true") != "false"
    count = OperationLogs::SelfReadMaintenance.new.purge!(dry_run: dry_run)
    status = dry_run ? "dry-run" : "deleted"
    puts "audit_log.index/show: #{count}件 (#{status})"
  end
end
