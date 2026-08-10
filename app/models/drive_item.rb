class DriveItem < ApplicationRecord
  STORAGE_KEY_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/

  belongs_to :organization
  belongs_to :owner_user, class_name: "User"
  belongs_to :purged_by_user, class_name: "User", optional: true

  belongs_to :parent,
             class_name: "DriveItem",
             optional: true

  has_many :children,
           class_name: "DriveItem",
           foreign_key: :parent_id,
           dependent: :destroy

  has_many :drive_item_access_logs, dependent: :destroy
  has_many :external_share_items, dependent: :destroy
  has_many :external_shares, through: :external_share_items

  enum :item_type, {
    file: 0,
    directory: 1
  }

  validates :name, presence: true
  validates :extension, presence: true, if: :file?

  # storage_key と blob_path は旧実装・現行実装の両方から参照されるため、
  # validation 前に単一の storage_key へ正規化して配信・削除処理の入口を揃える。
  before_validation :sync_storage_columns

  validate :parent_belongs_to_same_organization
  validate :parent_is_directory
  validate :parent_does_not_create_cycle
  validate :file_fields_match_item_type
  validate :storage_key_format

  scope :active, -> { where(deleted_at: nil, purged_at: nil) }
  scope :trashed, -> { where.not(deleted_at: nil).where(purged_at: nil) }
  scope :purged, -> { where.not(purged_at: nil) }
  scope :not_purged, -> { where(purged_at: nil) }
  scope :deleted, -> { trashed }

  def effective_storage_key
    storage_key.presence || blob_path.presence
  end

  def storage_relative_path
    self.class.storage_relative_path_for(effective_storage_key)
  end

  def absolute_storage_path
    self.class.storage_root.join(storage_relative_path)
  end

  def filename
    return name if extension.blank?
    return name if name.to_s.downcase.end_with?(".#{extension.downcase}")

    "#{name}.#{extension}"
  end

  def self.valid_storage_key?(value)
    # X-Accel-Redirect の内部 URI は storage_key から導出されるため、
    # ディレクトリ区切り・NUL・path traversal をここで拒否して Controller 側へ漏らさない。
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

  def self.storage_root
    Pathname.new(Rails.configuration.x.file_storage_root).expand_path
  end

  private

  def sync_storage_columns
    normalized_key = normalize_storage_key(storage_key.presence || blob_path.presence)

    self.storage_key = normalized_key
    self.blob_path = normalized_key.present? ? self.class.storage_relative_path_for(normalized_key) : nil
  end

  def parent_belongs_to_same_organization
    # 親子関係が organization を跨ぐと、親 ID 経由で別 tenant の階層情報が混ざる。
    # 取得時だけでなく保存時にも拒否して、後続の scope 漏れが情報漏洩にならない状態を保つ。
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
    # DB 固有の recursive CTE に寄せず Active Record で辿ることで、テスト DB と本番 DB の差を抑える。
    # 移動・復元時だけの検証なので、ここでは階層を明示的に breadth-first で収集する。
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

  def file_fields_match_item_type
    if directory?
      # ディレクトリが file 用カラムを持つと配信 Service から実体のない storage に到達し得る。
      errors.add(:extension, "must be blank") if extension.present?
      errors.add(:blob_path, "must be blank") if blob_path.present?
      errors.add(:storage_key, "must be blank") if storage_key.present?
      errors.add(:file_hash, "must be blank") if file_hash.present?
    end

    if file?
      return if purged_at.present?

      # purge 済みでない file は、監査後に Nginx へ渡せる保存キーを必ず持つ。
      # 物理削除後の record だけは参照保持のため storage 情報が欠けても許可する。
      errors.add(:extension, "is required") if extension.blank?
      errors.add(:blob_path, "is required") if blob_path.blank?
      errors.add(:storage_key, "is required") if storage_key.blank?
    end
  end

  def storage_key_format
    return unless file?
    return if purged_at.present?
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
