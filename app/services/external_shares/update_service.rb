module ExternalShares
  class UpdateService
    Result = Data.define(:success?, :status, :external_share, :error_message, :changes) do
      def self.success(external_share:, changes:)
        new(true, :ok, external_share, nil, changes)
      end

      def self.failure(status, error_message)
        new(false, status, nil, error_message, {})
      end
    end

    UPDATABLE_ATTRIBUTES = %i[name expires_at allow_download allow_bulk_download].freeze

    def initialize(external_share:, params:)
      @external_share = external_share
      @params = params
    end

    def call
      before = @external_share.slice(*UPDATABLE_ATTRIBUTES.map(&:to_s))
      @external_share.assign_attributes(@params.slice(*UPDATABLE_ATTRIBUTES))
      @external_share.password = @params[:password] if @params.key?(:password)
      return Result.success(external_share: @external_share, changes: {}) unless @external_share.changed?

      @external_share.save!
      Result.success(external_share: @external_share, changes: changed_values(before))
    rescue ActiveRecord::RecordInvalid => error
      Result.failure(:unprocessable_content, error.record.errors.full_messages.first || "外部公開を更新できませんでした")
    end

    private

    def changed_values(before)
      after = @external_share.slice(*UPDATABLE_ATTRIBUTES.map(&:to_s))
      before.each_with_object({}) do |(key, old_value), changes|
        new_value = after[key]
        changes[key] = [ old_value, new_value ] if old_value != new_value
      end
    end
  end
end
