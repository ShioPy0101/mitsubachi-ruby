class AddTrashBatchToDriveItems < ActiveRecord::Migration[8.1]
  def change
    add_column :drive_items, :trash_batch_id, :string
    add_column :drive_items, :trashed_by_ancestor_id, :bigint

    add_index :drive_items, :trash_batch_id
    add_index :drive_items, :trashed_by_ancestor_id
  end
end
