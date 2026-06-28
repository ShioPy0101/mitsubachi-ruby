class CreateDriveItemAccessLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :drive_item_access_logs do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :drive_item, null: false, foreign_key: true
      t.string :action
      t.datetime :accessed_at

      t.timestamps
    end
  end
end
