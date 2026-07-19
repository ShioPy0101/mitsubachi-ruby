require "test_helper"

class EmailAuthentications::MagicLinkDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
    @frontend_url = ENV["FRONTEND_URL"]
    ENV["FRONTEND_URL"] = "https://front.example"
  end

  teardown do
    ENV["FRONTEND_URL"] = @frontend_url
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
  end

  test "login purpose enqueues login_link without raw token job argument" do
    raw_token = "service-login-token"
    authentication = create_authentication(raw_token:, purpose: "login")

    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      EmailAuthentications::MagicLinkDelivery.call(
        email: authentication.email,
        organization: organizations(:one),
        authentication: authentication
      )
    end

    assert_equal "EmailAuthenticationMailer", enqueued_jobs.last.fetch("arguments").first
    assert_equal "login_link", enqueued_jobs.last.fetch("arguments").second
    refute_includes enqueued_jobs.last.to_s, raw_token
  end

  test "registration purpose enqueues registration_link without raw token job argument" do
    raw_token = "service-registration-token"
    authentication = create_authentication(raw_token:, purpose: "registration", organization_invite: organization_invites(:one))

    assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
      EmailAuthentications::MagicLinkDelivery.call(
        email: authentication.email,
        organization: organizations(:one),
        authentication: authentication
      )
    end

    assert_equal "EmailAuthenticationMailer", enqueued_jobs.last.fetch("arguments").first
    assert_equal "registration_link", enqueued_jobs.last.fetch("arguments").second
    refute_includes enqueued_jobs.last.to_s, raw_token
  end

  test "unknown purpose fails explicitly" do
    authentication = create_authentication(raw_token: "unknown-purpose-token", purpose: "login")
    authentication.update_column(:purpose, "password_reset")

    error = assert_raises ArgumentError do
      EmailAuthentications::MagicLinkDelivery.call(
        email: authentication.email,
        organization: organizations(:one),
        authentication: authentication
      )
    end

    assert_equal 'Unknown email authentication purpose: "password_reset"', error.message
  end

  test "performing parameterized login_link job does not raise missing mailer method" do
    raw_token = "perform-login-token"
    authentication = create_authentication(raw_token:, purpose: "login")

    assert_emails 1 do
      perform_enqueued_jobs do
        EmailAuthentications::MagicLinkDelivery.call(
          email: authentication.email,
          organization: organizations(:one),
          authentication: authentication
        )
      end
    end

    assert_includes ActionMailer::Base.deliveries.last.text_part.decoded, raw_token
  end

  private

  def create_authentication(raw_token:, purpose:, organization_invite: nil)
    EmailAuthentication.create!(
      email: "#{purpose}-delivery@example.com",
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      purpose: purpose,
      delivery_token: raw_token,
      organization_invite: organization_invite
    )
  end
end
