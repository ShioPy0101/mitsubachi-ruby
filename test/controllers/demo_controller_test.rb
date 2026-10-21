require "test_helper"

class DemoControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_mode = ENV["DEMO_MODE"]
    @original_flag = ENV["FEATURE_DEMO_TENANT"]
    ENV["DEMO_MODE"] = "true"
    ENV["FEATURE_DEMO_TENANT"] = "true"
    host! Demo::Access::API_HOST
    @headers = { "Origin" => Demo::Access::FRONTEND_ORIGIN }
    Rails.cache.clear
  end

  teardown do
    ENV["DEMO_MODE"] = @original_mode
    ENV["FEATURE_DEMO_TENANT"] = @original_flag
  end

  test "demo runtime refuses ordinary APIs even with real user cookies" do
    sign_in users(:one)
    get "/api/v1/me"
    assert_response :not_found
    post "/api/v1/drive_items", params: { name: "blocked" }
    assert_response :not_found
    get "/api/health/live"
    assert_response :ok
  end

  test "demo CORS allows only the dedicated frontend and bearer authorization" do
    app = ApiCors.new(->(_env) { [ 200, {}, [] ] })
    _, headers, = app.call({ "HTTP_ORIGIN" => Demo::Access::FRONTEND_ORIGIN, "REQUEST_METHOD" => "OPTIONS" })
    assert_equal Demo::Access::FRONTEND_ORIGIN, headers["Access-Control-Allow-Origin"]
    assert_includes headers["Access-Control-Allow-Headers"], "Authorization"
    _, headers, = app.call({ "HTTP_ORIGIN" => "https://mitsubachi.shiosalt.com", "REQUEST_METHOD" => "OPTIONS" })
    assert_nil headers["Access-Control-Allow-Origin"]
  end

  test "limits login email preview requests" do
    20.times { post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }, headers: @headers }
    post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }, headers: @headers
    assert_response :too_many_requests
  end

  test "requires demo host runtime and feature flag" do
    ENV["FEATURE_DEMO_TENANT"] = "false"
    post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }, headers: @headers
    assert_response :not_found
    ENV["FEATURE_DEMO_TENANT"] = "true"
    ENV["DEMO_MODE"] = "false"
    post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }, headers: @headers
    assert_response :not_found
    ENV["DEMO_MODE"] = "true"
    host! "mitsubachi-api.shiosalt.com"
    post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }, headers: @headers
    assert_response :not_found
  end

  test "rejects other emails origins and invalid tokens" do
    post "/api/v1/demo/login", params: { email: "real@example.com" }, headers: @headers
    assert_response :unprocessable_content
    post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }
    assert_response :forbidden
    post "/api/v1/demo/verify", params: { token: "invalid" }, headers: @headers
    assert_response :unauthorized
    get "/api/v1/demo/items"
    assert_response :unauthorized
  end

  test "email link grants only sample browsing and rejects all transfers" do
    assert_no_difference [ "User.count", "DriveItem.count", "EmailAuthentication.count" ] do
      post "/api/v1/demo/login", params: { email: Demo::Access::EMAIL }, headers: @headers
      assert_response :ok
      mail = response.parsed_body.fetch("email")
      assert_includes mail.fetch("body"), mail.fetch("url")
      token = Rack::Utils.parse_query(URI(mail.fetch("url")).query).fetch("token")
      post "/api/v1/demo/verify", params: { token: token }, headers: @headers
      assert_response :ok
      @headers["Authorization"] = "Bearer #{response.parsed_body.fetch('token')}"
      get "/api/v1/demo/items", headers: @headers
      assert_response :ok
      assert_equal 7, response.parsed_body.fetch("items").size
      assert_equal "no-store", response.headers["Cache-Control"]
      %w[upload download].each do |operation|
        post "/api/v1/demo/#{operation}", headers: @headers
        assert_response :forbidden
        assert_equal "demo_operation_restricted", response.parsed_body.dig("error", "code")
        assert_nil response.headers["X-Accel-Redirect"]
      end
    end
  end
end
