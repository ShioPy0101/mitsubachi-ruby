# テナント境界の静的検査を意図的に失敗させる検証用コード。
# API や job からは呼び出さず、検出結果を確認するためだけに使用する。
module TenantScopeViolationDemo
  def self.find_item(id)
    # organization.drive_items を経由しない検索を検出できることを示す。
    DriveItem.find(id)
  end
end
