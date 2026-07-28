class AllowDeletedExternalShareAccessActor < ActiveRecord::Migration[8.0]
  PREVIOUS_CHECK = <<~SQL.squish
    (actor_kind = 'user' AND user_id IS NOT NULL AND external_share_id IS NULL) OR
    (actor_kind = 'external_share' AND user_id IS NULL AND external_share_id IS NOT NULL) OR
    (actor_kind = 'anonymous' AND user_id IS NULL AND external_share_id IS NULL)
  SQL
  CHECK = <<~SQL.squish
    (actor_kind = 'user' AND user_id IS NOT NULL AND external_share_id IS NULL) OR
    (actor_kind = 'external_share' AND user_id IS NULL) OR
    (actor_kind = 'anonymous' AND user_id IS NULL AND external_share_id IS NULL)
  SQL

  def up
    remove_check_constraint :drive_item_access_logs, name: "drive_item_access_logs_actor_consistency"
    add_check_constraint :drive_item_access_logs, CHECK, name: "drive_item_access_logs_actor_consistency"
  end

  def down
    remove_check_constraint :drive_item_access_logs, name: "drive_item_access_logs_actor_consistency"
    add_check_constraint :drive_item_access_logs, PREVIOUS_CHECK, name: "drive_item_access_logs_actor_consistency"
  end
end
