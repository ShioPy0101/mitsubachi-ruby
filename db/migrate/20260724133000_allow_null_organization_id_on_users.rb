class AllowNullOrganizationIdOnUsers < ActiveRecord::Migration[8.0]
  def change
    change_column_null :users, :organization_id, true
  end
end
