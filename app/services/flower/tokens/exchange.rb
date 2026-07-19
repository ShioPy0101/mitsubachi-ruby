module Flower
  module Tokens
    class Exchange
      GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"
      ACCESS_TOKEN_TTL = 15.minutes

      Result = Data.define(:success?, :status, :error_code, :message, :token, :access_token) do
        def self.success(token:, access_token:)
          new(true, :ok, nil, nil, token, access_token)
        end

        def self.failure(status:, error_code:, message:)
          new(false, status, error_code, message, nil, nil)
        end
      end

      def initialize(grant_type:, device_code:, request:)
        @grant_type = grant_type
        @device_code = device_code
        @request = request
      end

      def call
        return failure("invalid_request", "Unsupported grant_type.") unless @grant_type == GRANT_TYPE
        return failure("invalid_grant", "Device code is invalid.") if @device_code.blank?
        authorization = FlowerDeviceAuthorization.find_by(device_code_digest: DeviceAuthorizations::Code.device_code_digest(@device_code))
        return failure("invalid_grant", "Device code is invalid.") if authorization.nil?

        authorization.with_lock do
          refresh_expiration!(authorization)
          return failure("access_denied", "Authorization was denied.") if authorization.denied?
          return failure("expired_token", "Device code expired.") if authorization.expired_status?
          return failure("invalid_grant", "Device code was already consumed.") if authorization.consumed?
          return slow_down if too_frequent?(authorization)

          authorization.update!(last_polled_at: Time.current)
          return pending if authorization.pending?
          return failure("invalid_grant", "Device code is invalid.") unless authorization.approved?

          issue_token!(authorization)
        end
      end

      private

      def issue_token!(authorization)
        raw_token = Codec.generate_token
        token = nil
        ActiveRecord::Base.transaction do
          token = FlowerAccessToken.create!(
            user: authorization.user,
            organization: authorization.organization,
            flower_device_authorization: authorization,
            access_token_digest: Codec.digest(raw_token),
            scopes: FlowerAccessToken::DEFAULT_SCOPES,
            expires_at: ACCESS_TOKEN_TTL.from_now
          )
          authorization.update!(status: "consumed", consumed_at: Time.current)
        end
        audit!("flower.token.issued", authorization, token, "success")
        Result.success(token:, access_token: raw_token)
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      def refresh_expiration!(authorization)
        return unless authorization.expired?
        return if authorization.terminal?

        authorization.update!(status: "expired")
      end

      def pending
        Result.failure(status: :bad_request, error_code: "authorization_pending", message: "Authorization is still pending.")
      end

      def slow_down
        Result.failure(status: :too_many_requests, error_code: "slow_down", message: "Polling is too frequent.")
      end

      def failure(code, message)
        Result.failure(status: :bad_request, error_code: code, message: message)
      end

      def too_frequent?(authorization)
        authorization.last_polled_at.present? &&
          authorization.last_polled_at > authorization.interval_seconds.seconds.ago
      end

      def audit!(action, authorization, token, outcome)
        AuditEvents::Recorder.record!(
          action: action,
          actor_user: authorization.user,
          organization: authorization.organization,
          target: token,
          outcome: outcome,
          metadata: {
            client_type: "flower",
            device_authorization_id: authorization.id,
            client_version: authorization.client_metadata["client_version"],
            scopes: token.scopes
          },
          request: @request
        )
      end
    end
  end
end
