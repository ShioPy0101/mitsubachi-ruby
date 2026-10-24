require "test_helper"

class EmailIdentities::MigrationTest < ActiveSupport::TestCase
  setup do
    @previous_key = ENV["EMAIL_IDENTITY_HMAC_KEY"]
    ENV["EMAIL_IDENTITY_HMAC_KEY"] = "migration-test-key-" * 3
    EmailIdentityKey.delete_all
    User.connection.execute("UPDATE users SET email_digest = NULL")
    User.connection.execute("UPDATE users SET email = 'test1@example.com' WHERE id = #{users(:one).id}")
    User.connection.execute("UPDATE users SET email = 'test2@example.com' WHERE id = #{users(:two).id}")
  end

  teardown do
    ENV["EMAIL_IDENTITY_HMAC_KEY"] = @previous_key
  end

  test "backfills and verifies legacy values without erasing them and is repeatable" do
    migration = EmailIdentities::Migration.new
    2.times { migration.backfill! }
    assert_equal "test1@example.com", User.connection.select_value("SELECT email FROM users WHERE id = #{users(:one).id}")
    assert_equal EmailIdentities::Digest.call("test1@example.com"), users(:one).reload.email_digest
    assert migration.verify!
  end

  test "changed key fails closed without rewriting data" do
    migration = EmailIdentities::Migration.new
    migration.backfill!
    original = users(:one).reload.email_digest
    ENV["EMAIL_IDENTITY_HMAC_KEY"] = "changed-test-key-" * 3
    assert_raises(EmailIdentities::Digest::ConfigurationError) { migration.backfill! }
    assert_equal original, users(:one).reload.email_digest
  end

  test "migrated outstanding magic link still authenticates after source columns are removed" do
    raw = "legacy-valid-token"
    token_digest = Digest::SHA256.hexdigest(raw)
    EmailAuthentication.connection.execute("INSERT INTO email_authentications (email, token, purpose, expires_at, created_at, updated_at) VALUES ('test1@example.com', '#{token_digest}', 'login', CURRENT_TIMESTAMP + INTERVAL '10 minutes', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
    migration = EmailIdentities::Migration.new
    migration.backfill!
    migration.finalize!
    assert_equal users(:one).id, Auth::MagicLinks.new.verify(raw).user.id
  end

  test "missing source and digest stops migration without manufacturing an identity" do
    User.connection.execute("UPDATE users SET email = NULL")
    assert_raises(RuntimeError) { EmailIdentities::Migration.new.backfill! }
    assert_nil users(:one).reload.email_digest
  end

  test "mismatch blocks source deletion" do
    migration = EmailIdentities::Migration.new
    migration.backfill!
    users(:one).update_column(:email_digest, "0" * 64)
    assert_raises(RuntimeError) { migration.finalize! }
    assert_equal "test1@example.com", User.connection.select_value("SELECT email FROM users WHERE id = #{users(:one).id}")
  end

  test "finalize erases source only after verification and blocks future plaintext writes" do
    migration = EmailIdentities::Migration.new
    migration.backfill!
    migration.finalize!
    assert_not User.connection.column_exists?(:users, :email)
    assert migration.verify!
    migration.finalize!
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        User.connection.execute("UPDATE users SET email = 'forbidden@example.com'")
      end
    end
  end
end
