module Flower
  module Downloads
    class Authorize
      Result = Data.define(:success?, :status, :error_code, :message, :drive_item) do
        def self.success(drive_item)
          new(true, :ok, nil, nil, drive_item)
        end

        def self.failure(status:, error_code:, message:)
          new(false, status, error_code, message, nil)
        end
      end

      def initialize(organization:, token:, id:)
        @organization = organization
        @token = token
        @id = id
      end

      def call
        return Result.failure(status: :forbidden, error_code: "insufficient_scope", message: "Download scope is required.") unless @token.has_scope?("flower:download")

        drive_item = @organization.drive_items.active.find_by(id: @id)
        return Result.failure(status: :not_found, error_code: "not_found", message: "Drive item was not found.") if drive_item.nil?
        return Result.failure(status: :unprocessable_content, error_code: "invalid_request", message: "Directories cannot be downloaded.") unless drive_item.file?

        Result.success(drive_item)
      end
    end
  end
end
