module Flower
  module Tokens
    class Authenticate
      Result = Data.define(:success?, :status, :error_code, :message, :token, :user, :organization, :scopes) do
        def self.success(token)
          new(true, :ok, nil, nil, token, token.user, token.organization, token.scopes)
        end

        def self.failure(status:, error_code:, message:)
          new(false, status, error_code, message, nil, nil, nil, [])
        end
      end

      def initialize(raw_token:, required_scopes: [])
        @raw_token = raw_token
        @required_scopes = Array(required_scopes)
      end

      def call
        return failure("invalid_token", "Bearer token is required.") if @raw_token.blank?

        token = FlowerAccessToken.includes(:user, :organization).find_by(access_token_digest: Codec.digest(@raw_token))
        return failure("invalid_token", "Bearer token is invalid.") if token.nil?
        return failure("invalid_token", "Bearer token is expired.") if token.expired?
        return failure("invalid_token", "Bearer token is revoked.") if token.revoked?
        return failure("invalid_token", "User is suspended.") if token.user.suspended?
        return failure("invalid_token", "Organization is invalid.") if token.user.organization_id != token.organization_id

        missing_scope = @required_scopes.find { |scope| !token.has_scope?(scope) }
        return Result.failure(status: :forbidden, error_code: "insufficient_scope", message: "Required scope is missing.") if missing_scope

        token.update_column(:last_used_at, Time.current)
        Result.success(token)
      end

      private

      def failure(code, message)
        Result.failure(status: :unauthorized, error_code: code, message: message)
      end
    end
  end
end
