class User < ApplicationRecord
  # 移行完了まで旧カラムはDBに残すが、通常の読み書き・serializationから除外する。
  self.ignored_columns += [ "email" ]
  attr_reader :email

  def email=(value)
    EmailIdentityKey.verify!
    @email = EmailIdentities::Digest.normalize(value)
    @email_assigned = true
    self.email_digest = @email.present? ? EmailIdentities::Digest.call(@email) : nil
  end

  def self.with_email(value)
    EmailIdentityKey.verify!
    where(email_digest: EmailIdentities::Digest.call(value))
  end

  # Devise の認証・Recoverable の両方が通る検索入口で変換する。
  # 宛先は呼び出し元が入力した値をそのリクエストのメモリ内だけに保持する。
  def self.find_first_by_auth_conditions(conditions, opts = {})
    values = conditions.to_h.with_indifferent_access
    return super unless values.key?(:email)

    email = values.delete(:email)
    with_email(email).find_by(values.merge(opts)).tap { |user| user.email = email if user }
  end

  def reload(*)
    @email = nil
    @email_assigned = false
    super
  end
  enum :role, {
    member: 0,
    organization_admin: 1,
    system_admin: 2
  }

  has_many :organization_memberships,
           dependent: :destroy
  has_many :organizations,
           through: :organization_memberships

  # users.organization_id は organization_memberships への段階的移行中の互換カラムとして残す
  belongs_to :organization, optional: true

  # このユーザーに付与されたDrivePermission
  has_many :drive_permissions, dependent: :restrict_with_error

  # このユーザーがアクセス権を持つDriveItem
  has_many :drive_items, through: :drive_permissions

  # このユーザーが使用した招待コード
  has_many :organization_invites,
           foreign_key: :used_by_user_id,
           dependent: :restrict_with_error

  has_many :user_email_changes, dependent: :restrict_with_error
  has_many :created_external_shares,
           class_name: "ExternalShare",
           foreign_key: :created_by_user_id,
           dependent: :restrict_with_error

  scope :active, -> { where(suspended_at: nil) }
  scope :suspended, -> { where.not(suspended_at: nil) }

  devise :database_authenticatable,
         :registerable,
         :recoverable,
         :rememberable

  before_validation :normalize_display_name

  # Devise Validatable のemail SQLは平文カラムを前提とするため、同じ入力検証を
  # 仮想属性に対して行い、永続identityの一意性はHMACとDB UNIQUEで保証する。
  validates :email_digest, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :email, presence: true, format: { with: Devise.email_regexp }, if: -> { @email_assigned }
  validate :email_digest_is_unique
  validates :password, presence: true, if: :password_required?
  validates :password, confirmation: true
  validates :password, length: { in: Devise.password_length }, allow_blank: true
  validates :display_name,
            length: { maximum: 100 },
            uniqueness: { scope: :organization_id, allow_blank: true }
  validate :display_name_has_no_control_characters

  def safe_display_name
    display_name.presence || name.presence || "未設定ユーザー"
  end

  def pending_email_change
    user_email_changes.active.order(created_at: :desc).first
  end

  def active_membership_for(organization)
    organization_memberships.active.find_by(organization: organization)
  end

  def suspended?
    suspended_at.present?
  end

  private

  # Devise は保存時にも仮想 email= を呼ぶため、再読込後の nil でdigestを消さない。
  # email= 自体が同じ正規化を行うので、この属性だけ標準callbackを迂回する。
  def apply_to_attribute_or_variable(attribute, method)
    return if attribute.to_sym == :email

    super
  end

  def password_required?
    !persisted? || !password.nil? || !password_confirmation.nil?
  end

  def email_digest_is_unique
    return if email_digest.blank?
    return unless self.class.where(email_digest: email_digest).where.not(id: id).exists?

    errors.add(:email, :taken)
  end

  def normalize_display_name
    self.display_name = display_name.to_s.strip.presence if display_name.present?
  end

  def display_name_has_no_control_characters
    return if display_name.blank?
    return unless display_name.match?(/[[:cntrl:]]/)

    errors.add(:display_name, "に制御文字は使用できません")
  end
end
