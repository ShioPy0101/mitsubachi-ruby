module Flower
  module DeviceAuthorizations
    class Deny
      Result = Data.define(:success?, :status, :error_code, :message, :authorization) do
        def self.success(authorization)
          new(true, :ok, nil, nil, authorization)
        end

        def self.failure(status:, error_code:, message:, authorization: nil)
          new(false, status, error_code, message, authorization)
        end
      end

      def initialize(user:, user_code:, request:)
        @user = user
        @user_code = user_code
        @request = request
      end

      def call
        return failure(:unauthorized, "invalid_token", "User is suspended.") if @user.suspended?

        authorization = FlowerDeviceAuthorization.find_by(user_code_digest: Code.user_code_digest(@user_code))
        return failure(:not_found, "not_found", "Device authorization was not found.") if authorization.nil?

        authorization.with_lock do
          return failure(:bad_request, "invalid_grant", "Device authorization is no longer pending.", authorization) unless authorization.pending?
          return expire!(authorization) if authorization.expired?

          authorization.update!(status: "denied", denied_at: Time.current)
          audit!(authorization, "success")
          Result.success(authorization)
        end
      end

      private

      def expire!(authorization)
        authorization.update!(status: "expired")
        failure(:bad_request, "expired_token", "Device authorization expired.", authorization)
      end

      def failure(status, code, message, authorization = nil)
        audit!(authorization, "denied", reason: code) if authorization
        Result.failure(status:, error_code: code, message:, authorization:)
      end

      def audit!(authorization, outcome, metadata = {})
        AuditEvents::Recorder.record!(
          action: "flower.authorization.denied",
          actor_user: @user,
          organization: @user.organization,
          target: authorization,
          outcome: outcome,
          metadata: {
            client_type: "flower",
            device_authorization_id: authorization&.id,
            client_version: authorization&.client_metadata&.fetch("client_version", nil)
          }.merge(metadata),
          request: @request
        )
      end
    end
  end
end
