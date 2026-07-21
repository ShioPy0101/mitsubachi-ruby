require "digest"
require "securerandom"

module ExternalShares
  class CreateService
    Result = Data.define(:success?, :status, :external_share, :raw_token, :generated_password, :error_message) do
      def self.success(external_share:, raw_token:, generated_password:)
        new(true, :created, external_share, raw_token, generated_password, nil)
      end

      def self.failure(status, error_message)
        new(false, status, nil, nil, nil, error_message)
      end
    end

    def initialize(user:, params:)
      @user = user
      @organization = user.organization
      @params = params
    end

    def call
      drive_item_ids = Array(@params[:drive_item_ids]).reject(&:blank?).map(&:to_i).uniq
      return Result.failure(:unprocessable_content, "公開対象を選択してください") if drive_item_ids.empty?

      roots = @organization.drive_items.active.where(id: drive_item_ids).order(:id).to_a
      return Result.failure(:not_found, "公開対象が見つかりません") unless roots.size == drive_item_ids.size

      mode = @params[:folder_share_mode].presence || "snapshot"
      return Result.failure(:unprocessable_content, "フォルダ共有方式が不正です") unless ExternalShare.folder_share_modes.key?(mode)

      raw_token, token_digest = generate_unique_token
      generated_password = password_protected? ? PasswordGenerator.generate : nil
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
          password: generated_password
        )

        item_ids_for(share, roots).each do |drive_item_id|
          share.external_share_items.create!(drive_item_id: drive_item_id)
        end
      end

      Result.success(external_share: share, raw_token: raw_token, generated_password: generated_password)
    rescue ActiveRecord::RecordInvalid => error
      Result.failure(:unprocessable_content, error.record.errors.full_messages.first || "外部公開を作成できませんでした")
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

    def password_protected?
      boolean_param(:password_protected, false)
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
