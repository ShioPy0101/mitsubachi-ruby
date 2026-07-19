module Flower
  module DeviceAuthorizations
    class Approve
      Result = Data.define(:success?, :status, :error_code, :message, :authorization) do
        def self.success(authorization)
          new(true, :ok, nil, nil, authorization)
        end

        def self.failure(status:, error_code:, message:, authorization: nil)
          new(false, status, error_code, message, authorization)
        end
      end

      def initialize(user:, user_code:, organization_id:, request:)
        @user = user
        @user_code = user_code
        @organization_id = organization_id
        @request = request
      end

      def call
        return failure(:unauthorized, "invalid_token", "User is suspended.") if @user.suspended?

        authorization = find_authorization
        return failure(:not_found, "not_found", "Device authorization was not found.") if authorization.nil?

        authorization.with_lock do
          return terminal_failure(authorization) unless authorization.pending?
          return expire!(authorization) if authorization.expired?
          return failure(:forbidden, "access_denied", "Organization is not allowed.", authorization) unless allowed_organization?

          authorization.update!(
            status: "approved",
            user: @user,
            organization_id: @organization_id,
            approved_at: Time.current
          )
          audit!("flower.authorization.approved", authorization, "success")
          Result.success(authorization)
        end
      end

      private

      def find_authorization
        FlowerDeviceAuthorization.find_by(user_code_digest: Code.user_code_digest(@user_code))
      end

      def allowed_organization?
        @user.organization_id.to_s == @organization_id.to_s
      end

      def expire!(authorization)
        authorization.update!(status: "expired")
        failure(:bad_request, "expired_token", "Device authorization expired.", authorization)
      end

      def terminal_failure(authorization)
        code = authorization.denied? ? "access_denied" : "invalid_grant"
        failure(:bad_request, code, "Device authorization is no longer pending.", authorization)
      end

      def failure(status, code, message, authorization = nil)
        audit!("flower.authorization.approved", authorization, "denied", reason: code) if authorization
        Result.failure(status:, error_code: code, message:, authorization:)
      end

      def audit!(action, authorization, outcome, metadata = {})
        AuditEvents::Recorder.record!(
          action: action,
          actor_user: @user,
          organization: authorization&.organization || @user.organization,
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
