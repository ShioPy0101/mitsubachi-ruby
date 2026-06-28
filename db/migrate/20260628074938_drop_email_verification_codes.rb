class DropEmailVerificationCodes < ActiveRecord::Migration[8.1]
  def change
    drop_table :email_verification_codes
  end
end
