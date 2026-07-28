class Organization < ApplicationRecord
    has_many :organization_memberships,
             dependent: :destroy

    has_many :users,
             through: :organization_memberships

    has_many :legacy_users,
             class_name: "User",
             dependent: :restrict_with_error

    # 組織に属する招待を取得する
    has_many :organization_invites, dependent: :restrict_with_error

    # 組織に属するドライブアイテムを取得する
    has_many :drive_items, dependent: :restrict_with_error
    has_many :drive_item_access_logs, dependent: :restrict_with_error
    has_many :admin_audit_logs, dependent: :restrict_with_error
    has_many :operation_logs, dependent: :restrict_with_error
    has_many :audit_events, dependent: :restrict_with_error
    has_many :external_shares, dependent: :restrict_with_error
    has_many :flower_device_authorizations, dependent: :restrict_with_error
    has_many :flower_access_tokens, dependent: :restrict_with_error

    validates :name, presence: true
end
