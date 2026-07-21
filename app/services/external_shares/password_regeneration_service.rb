module ExternalShares
  class PasswordRegenerationService
    Result = Data.define(:success?, :external_share, :generated_password, :error_message) do
      def self.success(external_share:, generated_password:)
        new(true, external_share, generated_password, nil)
      end

      def self.failure(error_message)
        new(false, nil, nil, error_message)
      end
    end

    def initialize(external_share:)
      @external_share = external_share
    end

    def call
      generated_password = PasswordGenerator.generate
      @external_share.update!(password: generated_password)
      Result.success(external_share: @external_share, generated_password: generated_password)
    rescue ActiveRecord::RecordInvalid => error
      Result.failure(error.record.errors.full_messages.first || "パスワードを再発行できませんでした")
    end
  end
end
