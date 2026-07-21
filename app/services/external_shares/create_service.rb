require "digest"
require "securerandom"

module ExternalShares
  class CreateService
    Result = Data.define(:success?, :status, :external_share, :raw_token, :error_message) do
      def self.success(external_share:, raw_token:)
        new(true, :created, external_share, raw_token, nil)
      end

      def self.failure(status, error_message)
        new(false, status, nil, nil, error_message)
      end
    end

    def initialize(user:, params:)
      @user = user
      @organization = user.organization
      @params = params
    end

    def call
      drive_item_ids = Array(@params[:drive_item_ids]).reject(&:blank?).map(&:to_i).uniq
      return Result.failure(:unprocessable_entity, "公開対象を選択してください") if drive_item_ids.empty?

      roots = @organization.drive_items.active.where(id: drive_item_ids).order(:id).to_a
      return Result.failure(:not_found, "公開対象が見つかりません") unless roots.size == drive_item_ids.size

      mode = @params[:folder_share_mode].presence || "snapshot"
      return Result.failure(:unprocessable_entity, "フォルダ共有方式が不正です") unless ExternalShare.folder_share_modes.key?(mode)

      raw_token, token_digest = generate_unique_token
      share = nil

      ActiveRecord::Base.transaction do
        share = ExternalShare.create!(
          organization: @organization,
          created_by_user: @user,
          name: @params[:name],
          token_digest: token_digest,
          folder_share_mode: mode,
          expires_at: @params[:expires_at],
          allow_download: boolean_param(:allow_download, true),
          allow_bulk_download: boolean_param(:allow_bulk_download, false),
          password: @params[:password].presence
        )

        item_ids_for(share, roots).each do |drive_item_id|
          share.external_share_items.create!(drive_item_id: drive_item_id)
        end
      end

      Result.success(external_share: share, raw_token: raw_token)
    rescue ActiveRecord::RecordInvalid => error
      Result.failure(:unprocessable_entity, error.record.errors.full_messages.first || "外部公開を作成できませんでした")
    end

    private

    def item_ids_for(share, roots)
      if share.snapshot?
        SnapshotBuilder.new(organization: @organization, roots: roots).item_ids
      else
        roots.select(&:directory?).map(&:id) + roots.select(&:file?).map(&:id)
      end.uniq
    end

    def boolean_param(key, default)
      return default unless @params.key?(key)

      ActiveModel::Type::Boolean.new.cast(@params[key])
    end

    def generate_unique_token
      10.times do
        raw_token = SecureRandom.urlsafe_base64(32)
        token_digest = Digest::SHA256.hexdigest(raw_token)
        return [ raw_token, token_digest ] unless ExternalShare.exists?(token_digest: token_digest)
      end

      raise ActiveRecord::RecordNotUnique, "external share token collision"
    end
  end
end
