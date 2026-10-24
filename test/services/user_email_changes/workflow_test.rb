require "test_helper"

class UserEmailChanges::WorkflowTest < ActiveSupport::TestCase
  setup do
    @frontend_url = ENV["FRONTEND_URL"]
    ENV["FRONTEND_URL"] = "https://front.example"
    ActionMailer::Base.deliveries.clear
    @user = users(:one)
  end

  teardown do
    ENV["FRONTEND_URL"] = @frontend_url
  end

  test "requires dedicated recent reauthentication and consumes it once" do
    assert_raises(UserEmailChanges::ConfirmService::Failure) { request_change }
    regular = Auth::MagicLinks.new.request_login(email: "test1@example.com")
    Auth::MagicLinks.new.verify(regular.token)
    assert_raises(UserEmailChanges::ConfirmService::Failure) { request_change(regular.authentication.id) }
    id = reauthenticate
    travel 6.minutes do
      assert_raises(UserEmailChanges::ConfirmService::Failure) { request_change(id) }
    end
    request_change(id)
    assert_raises(UserEmailChanges::ConfirmService::Failure) { request_change(id) }
  end

  test "old approval then new confirmation changes identity and notifies old address" do
    result = request_change(reauthenticate)
    change = result.email_change.reload
    original_digest = @user.reload.email_digest
    assert_equal [ "test1@example.com" ], ActionMailer::Base.deliveries.last.to
    assert_nil change.new_email
    refute_includes change.attributes.to_json, "@example.com"
    assert_raises(UserEmailChanges::ConfirmService::Failure) { UserEmailChanges::ConfirmService.new(token: result.token).call }
    UserEmailChanges::ConfirmService.new(token: result.token).approve
    assert_equal original_digest, @user.reload.email_digest
    assert_equal [ "new@example.com" ], ActionMailer::Base.deliveries.last.to
    new_token = confirmation_token
    assert_raises(UserEmailChanges::ConfirmService::Failure) { UserEmailChanges::ConfirmService.new(token: result.token).approve }
    UserEmailChanges::ConfirmService.new(token: new_token).call
    assert_equal EmailIdentities::Digest.call("new@example.com"), @user.reload.email_digest
    assert_equal [ "test1@example.com" ], ActionMailer::Base.deliveries.last.to
    assert_nil change.reload.delivery_addresses_ciphertext
    assert_nil User.with_email("test1@example.com").first
    assert_equal @user.id, User.with_email(" NEW@example.com ").first.id
    assert_raises(UserEmailChanges::ConfirmService::Failure) { UserEmailChanges::ConfirmService.new(token: new_token).call }
  end

  test "expiry suspension cancellation and intervening identity changes block approval" do
    result = request_change(reauthenticate)
    service = UserEmailChanges::ConfirmService.new(token: result.token)
    travel 31.minutes do
      assert_raises(UserEmailChanges::ConfirmService::Failure) { service.approve }
    end
    @user.update!(suspended_at: Time.current)
    assert_raises(UserEmailChanges::ConfirmService::Failure) { service.approve }
    @user.update!(suspended_at: nil, email: "intervening@example.com")
    assert_raises(UserEmailChanges::ConfirmService::Failure) { service.approve }
    @user.update!(email: "test1@example.com")
    result.email_change.update!(cancelled_at: Time.current)
    assert_raises(UserEmailChanges::ConfirmService::Failure) { service.approve }
  end

  test "new address claimed before final confirmation prevents account update" do
    result = request_change(reauthenticate)
    UserEmailChanges::ConfirmService.new(token: result.token).approve
    token = confirmation_token
    User.create!(email: "new@example.com", password: "password123")
    assert_raises(UserEmailChanges::ConfirmService::Failure) { UserEmailChanges::ConfirmService.new(token: token).call }
    assert_equal EmailIdentities::Digest.call("test1@example.com"), @user.reload.email_digest
  end

  private

  def reauthenticate
    result = Auth::MagicLinks.new.request_login(email: "test1@example.com", intent: "email_change")
    Auth::MagicLinks.new.verify(result.token)
    result.authentication.id
  end

  def request_change(id = nil)
    UserEmailChanges::RequestService.new(user: @user, email: " New@Example.com ", reauthentication_id: id).call
  end

  def confirmation_token
    url = ActionMailer::Base.deliveries.last.text_part.decoded.lines.find { |line| line.start_with?("https://") }.strip
    Rack::Utils.parse_query(URI(url).query).fetch("token")
  end
end
