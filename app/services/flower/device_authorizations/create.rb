module Flower
  module DeviceAuthorizations
    class Create
      EXPIRES_IN = 10.minutes
      INTERVAL_SECONDS = 5
      RATE_LIMIT = 20
      RATE_LIMIT_PERIOD = 10.minutes
      VERIFICATION_PATH = "/flower/activate"

      Result = Data.define(:success?, :status, :error_code, :message, :authorization, :device_code, :user_code) do
        def self.success(authorization:, device_code:, user_code:)
          new(true, :ok, nil, nil, authorization, device_code, user_code)
        end

        def self.failure(status:, error_code:, message:)
          new(false, status, error_code, message, nil, nil, nil)
        end
      end

      def initialize(client_name:, client_version:, device_name:, request:)
        @client_name = client_name.to_s
        @client_version = client_version.to_s
        @device_name = device_name.to_s
        @request = request
      end

      def call
        return rate_limited unless rate_limit.allowed?

        device_code = Code.device_code
        user_code = Code.user_code
        authorization = FlowerDeviceAuthorization.create!(
          device_code_digest: Code.device_code_digest(device_code),
          user_code_digest: Code.user_code_digest(user_code),
          expires_at: EXPIRES_IN.from_now,
          interval_seconds: INTERVAL_SECONDS,
          client_metadata: client_metadata
        )

        audit!("flower.device_authorization.created", authorization, "success")
        Result.success(authorization:, device_code:, user_code:)
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      private

      def rate_limited
        Result.failure(status: :too_many_requests, error_code: "rate_limited", message: "Too many device authorization requests.")
      end

      def rate_limit
        Security::RateLimiter.new(
          namespace: "flower-device-create-ip",
          key: @request.remote_ip,
          limit: RATE_LIMIT,
          period: RATE_LIMIT_PERIOD
        ).call
      end

      def client_metadata
        {
          client_name: @client_name.first(100),
          client_version: @client_version.first(50),
          device_name: @device_name.first(150)
        }.compact
      end

      def audit!(action, authorization, outcome)
        AuditEvents::Recorder.record!(
          action: action,
          target: authorization,
          outcome: outcome,
          metadata: {
            client_type: "flower",
            client_name: @client_name.first(100),
            client_version: @client_version.first(50),
            device_authorization_id: authorization.id
          },
          request: @request
        )
      end
    end
  end
end
