class CreateEmailVerificationCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :email_verification_codes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :code_digest
      t.datetime :expires_at
      t.datetime :used_at

      t.timestamps
    end
  end
end
