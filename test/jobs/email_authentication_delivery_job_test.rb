require "test_helper"

class EmailAuthenticationDeliveryJobTest < ActiveSupport::TestCase
  test "SMTP recipient and original cause do not escape into job failure logs" do
    original = EmailAuthenticationMailer.method(:with)
    message = Object.new
    message.define_singleton_method(:login_link) { self }
    message.define_singleton_method(:deliver_now) { raise Net::SMTPFatalError, "rejected private@example.com" }
    EmailAuthenticationMailer.define_singleton_method(:with) { |**| message }
    error = assert_raises(EmailAuthenticationDeliveryJob::DeliveryError) do
      EmailAuthenticationDeliveryJob.new.perform("EmailAuthenticationMailer", "login_link", "deliver_now", params: {}, args: [])
    end
    refute_includes error.message, "private@example.com"
    assert_nil error.cause
    assert_not EmailAuthenticationDeliveryJob.log_arguments
  ensure
    EmailAuthenticationMailer.define_singleton_method(:with, original)
  end
end
