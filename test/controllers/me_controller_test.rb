require "test_helper"

class MeControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = users(:one)
    @frontend_url = ENV["FRONTEND_URL"]
    ENV["FRONTEND_URL"] = "https://front.example"
    sign_in @user
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ENV["FRONTEND_URL"] = @frontend_url
    travel_back
  end

  test "requires login to update current user" do
    sign_out @user

    patch api_v1_me_url, params: { display_name: "新しい表示名" }

    assert_response :unauthorized
  end

  test "returns current user with pending email" do
    @user.user_email_changes.create!(
      new_email: "pending@example.com",
      token_digest: UserEmailChange.digest_token("pending-token"),
      expires_at: 30.minutes.from_now
    )

    get api_v1_me_url

    assert_response :ok
    assert_equal "pending@example.com", response.parsed_body.dig("data", "pending_email")
  end

  test "updates display name and records audit event" do
    assert_difference "AuditEvent.where(action: 'user.profile.update').count", 1 do
      patch api_v1_me_url, params: {
        display_name: "  新しい表示名  ",
        role: "system_admin",
        organization_id: organizations(:two).id
      }
    end

    assert_response :ok
    @user.reload
    assert_equal "新しい表示名", @user.display_name
    assert_equal "member", @user.role
    assert_equal organizations(:one).id, @user.organization_id
    assert_equal "新しい表示名", response.parsed_body.dig("data", "display_name")
  end

  test "rejects blank display name" do
    patch api_v1_me_url, params: { display_name: "   " }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  test "rejects too long display name" do
    patch api_v1_me_url, params: { display_name: "あ" * 101 }

    assert_response :unprocessable_entity
    assert_equal "validation_failed", response.parsed_body.dig("error", "code")
  end

  test "requests email change without changing current email" do
    assert_difference "UserEmailChange.count", 1 do
      assert_difference "AuditEvent.where(action: 'user.email_change.request').count", 1 do
        post email_change_api_v1_me_url, params: { email: " NewEmail@Example.com " }
      end
    end

    assert_response :ok
    assert_equal "test1@example.com", @user.reload.email
    assert_equal "newemail@example.com", @user.pending_email_change.new_email
    assert_equal "newemail@example.com", response.parsed_body.fetch("pending_email")
    assert_equal 1, ActionMailer::Base.deliveries.size
    refute_includes @user.pending_email_change.token_digest, "NewEmail"
  end

  test "rejects duplicate email change request" do
    assert_no_difference "UserEmailChange.count" do
      post email_change_api_v1_me_url, params: { email: users(:two).email }
    end

    assert_response :unprocessable_entity
  end

  test "rejects invalid email change request" do
    assert_no_difference "UserEmailChange.count" do
      post email_change_api_v1_me_url, params: { email: "invalid-email" }
    end

    assert_response :unprocessable_entity
  end

  test "rejects current email change request" do
    assert_no_difference "UserEmailChange.count" do
      post email_change_api_v1_me_url, params: { email: " TEST1@example.com " }
    end

    assert_response :unprocessable_entity
  end

  test "does not persist email change request when delivery fails" do
    original_delivery = UserEmailChangeMailer.method(:with)
    failing_message = Object.new
    failing_message.define_singleton_method(:confirmation) { self }
    failing_message.define_singleton_method(:deliver_now) { raise Net::SMTPFatalError, "delivery failed" }
    UserEmailChangeMailer.define_singleton_method(:with) { |**| failing_message }

    assert_no_difference "UserEmailChange.count" do
      post email_change_api_v1_me_url, params: { email: "delivery-failure@example.com" }
    end

    assert_response :unprocessable_entity
    assert_equal "test1@example.com", @user.reload.email
  ensure
    UserEmailChangeMailer.define_singleton_method(:with, original_delivery)
  end

  test "verifies email change with valid token and notifies old email" do
    raw_token = "valid-email-change-token"
    @user.user_email_changes.create!(
      new_email: "verified@example.com",
      token_digest: UserEmailChange.digest_token(raw_token),
      expires_at: 30.minutes.from_now
    )
    sign_out @user

    assert_difference "AuditEvent.where(action: 'user.email_change.confirm').count", 1 do
      post email_change_verify_api_v1_me_url, params: { token: raw_token }
      assert_response :ok
    end

    assert_equal "verified@example.com", @user.reload.email
    assert @user.user_email_changes.last.used_at.present?
    assert_equal [ "test1@example.com" ], ActionMailer::Base.deliveries.last.to
  end

  test "rejects invalid email change token" do
    post email_change_verify_api_v1_me_url, params: { token: "wrong-token" }

    assert_response :unprocessable_entity
  end

  test "rejects expired email change token" do
    raw_token = "expired-email-change-token"
    @user.user_email_changes.create!(
      new_email: "expired@example.com",
      token_digest: UserEmailChange.digest_token(raw_token),
      expires_at: 1.minute.ago
    )

    post email_change_verify_api_v1_me_url, params: { token: raw_token }

    assert_response :gone
    assert_equal "test1@example.com", @user.reload.email
  end

  test "rejects used email change token" do
    raw_token = "used-email-change-token"
    @user.user_email_changes.create!(
      new_email: "used@example.com",
      token_digest: UserEmailChange.digest_token(raw_token),
      expires_at: 30.minutes.from_now,
      used_at: 1.minute.ago
    )

    post email_change_verify_api_v1_me_url, params: { token: raw_token }

    assert_response :gone
  end

  test "cancels pending email change" do
    @user.user_email_changes.create!(
      new_email: "cancel@example.com",
      token_digest: UserEmailChange.digest_token("cancel-token"),
      expires_at: 30.minutes.from_now
    )

    assert_difference "AuditEvent.where(action: 'user.email_change.cancel').count", 1 do
      delete email_change_api_v1_me_url
    end

    assert_response :ok
    assert_nil @user.reload.pending_email_change
  end

  test "rate limits email change requests" do
    5.times do
      sign_in @user
      post email_change_api_v1_me_url, params: { email: "limited@example.com" }
      assert_response :ok
    end

    sign_in @user
    post email_change_api_v1_me_url, params: { email: "limited@example.com" }

    assert_response :too_many_requests
    assert_equal "900", response.headers["Retry-After"]
  end
end
