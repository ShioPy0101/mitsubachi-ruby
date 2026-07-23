namespace :mitsubachi do
  desc "Repair active descendants under trashed drive item directories"
  task repair_trashed_descendants: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", "true"))
    inspected_roots = 0
    repaired_items = 0

    DriveItem
      .directory
      .where.not(deleted_at: nil)
      .where(purged_at: nil)
      .order(:organization_id, :id)
      .find_each do |root|
        inspected_roots += 1
        batch_id = root.trash_batch_id.presence || SecureRandom.uuid
        items = DriveItems::TreeCollector.new(root: root).call
        targets = items.select { |item| item.id != root.id && item.deleted_at.nil? && item.purged_at.nil? }
        next if targets.empty?

        repaired_items += targets.size
        next if dry_run

        ActiveRecord::Base.transaction do
          root.update!(
            trash_batch_id: batch_id,
            trashed_by_ancestor_id: root.trashed_by_ancestor_id || root.id
          )
          targets.each do |item|
            item.update!(
              deleted_at: root.deleted_at,
              trash_batch_id: batch_id,
              trashed_by_ancestor_id: root.id
            )
          end
        end
      end

    Rails.logger.info(
      "[mitsubachi:repair_trashed_descendants] dry_run=#{dry_run} " \
      "inspected_roots=#{inspected_roots} repairable_items=#{repaired_items}"
    )
    puts "dry_run=#{dry_run} inspected_roots=#{inspected_roots} repairable_items=#{repaired_items}"
  end
end
