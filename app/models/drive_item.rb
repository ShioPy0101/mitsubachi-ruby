# app/models/drive_item.rb
class DriveItem < ApplicationRecord
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

  # 保存する直前に、検査
  validate :parent_belongs_to_same_organization
  validate :file_fields_match_item_type

  # スコープの定義

  # activeなDriveItemを取得するスコープ
  scope :active, -> { where(deleted_at: nil) }

  # deletedなDriveItemを取得するスコープ
  scope :deleted, -> { where.not(deleted_at: nil) }

  private

  # 親DriveItemが同じ組織に属しているかを検査する
  def parent_belongs_to_same_organization
    return unless parent
    return if parent.organization_id == organization_id

    errors.add(:parent, "must belong to the same organization")
  end

  # item_typeに応じて、必要なフィールドが正しく設定されているかを検査する
  def file_fields_match_item_type
    if directory?

      # ディレクトリの場合、extension, blob_path, file_hashは空であるべき
      errors.add(:extension, "must be blank") if extension.present?
      errors.add(:blob_path, "must be blank") if blob_path.present?
      errors.add(:file_hash, "must be blank") if file_hash.present?
    end

    if file?

      # ファイルの場合、extension, blob_path, file_hashは必須である
      errors.add(:extension, "is required") if extension.blank?
      errors.add(:blob_path, "is required") if blob_path.blank?
    end
  end
end
