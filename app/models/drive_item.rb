# app/models/drive_item.rb
class DriveItem < ApplicationRecord
  STORAGE_KEY_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/

  # DriveItemは一つの組織に属する
  belongs_to :organization

  # DriveItemは一つのオーナーユーザーに属する
  belongs_to :owner_user, class_name: "User"

  # DriveItemは親DriveItemに属することができる（ディレクトリ構造を形成するため）
  belongs_to :parent,
             class_name: "DriveItem",
             optional: true # 親がいない場合もある（ルートディレクトリなど）

  # DriveItemは複数の子DriveItemを持つことができる
  has_many :children,
           class_name: "DriveItem",
           foreign_key: :parent_id,
           dependent: :destroy

  # DriveItemはアクセスログを持つことができる
  has_many :drive_item_access_logs, dependent: :destroy

  # DriveItemはitem_typeによってファイルかディレクトリかを区別する
  enum :item_type, {
    file: 0,
    directory: 1
  }

  # ここから下はバリデーションの定義

  # nameは必須である
  validates :name, presence: true

  # extensionは、item_typeがfileの場合に必須である
  validates :extension, presence: true, if: :file?

  before_validation :sync_storage_columns

  # 保存する直前に、検査
  validate :parent_belongs_to_same_organization
  validate :parent_is_directory
  validate :parent_does_not_create_cycle
  validate :file_fields_match_item_type
  validate :storage_key_format

  # スコープの定義

  # activeなDriveItemを取得するスコープ
  scope :active, -> { where(deleted_at: nil) }

  # deletedなDriveItemを取得するスコープ
  scope :deleted, -> { where.not(deleted_at: nil) }

  def effective_storage_key
    storage_key.presence || blob_path.presence
  end

  def storage_relative_path
    self.class.storage_relative_path_for(effective_storage_key)
  end

  def absolute_storage_path
    Rails.root.join("storage", storage_relative_path)
  end

  def filename
    return name if extension.blank?
    return name if name.to_s.downcase.end_with?(".#{extension.downcase}")

    "#{name}.#{extension}"
  end

  def self.valid_storage_key?(value)
    return false if value.blank?
    return false if value.include?("/")
    return false if value.start_with?("/", "\\")
    return false if value.include?("..")
    return false if value.include?("\\")
    return false if value.include?("\0")

    value.match?(STORAGE_KEY_PATTERN)
  end

  def self.storage_relative_path_for(storage_key)
    return if storage_key.blank?

    File.join("drive_items", storage_key)
  end

  private

  def sync_storage_columns
    normalized_key = normalize_storage_key(storage_key.presence || blob_path.presence)

    self.storage_key = normalized_key
    self.blob_path = normalized_key.present? ? self.class.storage_relative_path_for(normalized_key) : nil
  end

  # 親DriveItemが同じ組織に属しているかを検査する
  def parent_belongs_to_same_organization
    return unless parent
    return if parent.organization_id == organization_id

    errors.add(:parent, "must belong to the same organization")
  end

  def parent_is_directory
    return unless parent
    return if parent.directory?

    errors.add(:parent, "must be a directory")
  end

  def parent_does_not_create_cycle
    return if parent_id.blank? || id.blank?

    if parent_id == id
      errors.add(:parent, "cannot be self")
      return
    end

    return unless descendant_ids.include?(parent_id)

    errors.add(:parent, "cannot be a descendant")
  end

  def descendant_ids
    ids = []
    current_parent_ids = [ id ]

    loop do
      child_ids = self.class.where(parent_id: current_parent_ids).pluck(:id)
      child_ids -= ids
      break if child_ids.empty?

      ids.concat(child_ids)
      current_parent_ids = child_ids
    end

    ids
  end

  # item_typeに応じて、必要なフィールドが正しく設定されているかを検査する
  def file_fields_match_item_type
    if directory?

      # ディレクトリの場合、extension, blob_path, storage_key, file_hashは空であるべき
      errors.add(:extension, "must be blank") if extension.present?
      errors.add(:blob_path, "must be blank") if blob_path.present?
      errors.add(:storage_key, "must be blank") if storage_key.present?
      errors.add(:file_hash, "must be blank") if file_hash.present?
    end

    if file?

      # ファイルの場合、extension, blob_path, storage_key, file_hashは必須である
      errors.add(:extension, "is required") if extension.blank?
      errors.add(:blob_path, "is required") if blob_path.blank?
      errors.add(:storage_key, "is required") if storage_key.blank?
    end
  end

  def storage_key_format
    return unless file?
    return if self.class.valid_storage_key?(storage_key)

    errors.add(:storage_key, "is invalid")
  end

  def normalize_storage_key(value)
    return if value.blank?

    candidate = value.to_s.delete_prefix("/")
    candidate = candidate.delete_prefix("drive_items/")
    File.basename(candidate)
  end
end
