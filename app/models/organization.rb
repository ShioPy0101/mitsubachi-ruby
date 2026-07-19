class Organization < ApplicationRecord
    # 組織に属するユーザーを取得する
    has_many :users, dependent: :restrict_with_error

    # 組織に属する招待を取得する
    has_many :organization_invites, dependent: :restrict_with_error

    # 組織に属するドライブアイテムを取得する
    has_many :drive_items, dependent: :restrict_with_error
    has_many :flower_device_authorizations, dependent: :restrict_with_error
    has_many :flower_access_tokens, dependent: :restrict_with_error

    validates :name, presence: true
end
