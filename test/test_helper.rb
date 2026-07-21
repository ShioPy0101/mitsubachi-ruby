ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "devise"
require "digest"
require "securerandom"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def sign_in_with_magic_link(user)
    raw_token = SecureRandom.urlsafe_base64(32)
    EmailAuthentication.create!(
      email: user.email,
      token: Digest::SHA256.hexdigest(raw_token),
      expires_at: 15.minutes.from_now,
      purpose: "login"
    )

    post api_v1_auth_verify_url, params: { token: raw_token }
    assert_response :ok
  end
end
