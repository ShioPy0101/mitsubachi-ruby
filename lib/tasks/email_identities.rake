namespace :mitsubachi do
  namespace :email_identities do
    desc "Backfill email HMAC digests without deleting source data"
    task backfill: :environment do
      EmailIdentities::Migration.new.backfill!
      puts "Email digest backfill and verification succeeded"
    end

    desc "Verify all email digests against remaining source data"
    task verify: :environment do
      EmailIdentities::Migration.new.verify!
      puts "Email digest verification succeeded"
    end

    desc "Redact email addresses in existing structured audit and system logs"
    task scrub_logs: :environment do
      EmailIdentities::ScrubLogs.new.call
      puts "Historical log email redaction succeeded"
    end

    desc "After verification, erase legacy email values (requires stopped writers)"
    task finalize: :environment do
      EmailIdentities::Migration.new.finalize!
      puts "Legacy email values erased; plaintext writes now prohibited"
    end
  end
end
