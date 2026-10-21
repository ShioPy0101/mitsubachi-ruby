# 公開機能の段階的な有効化を管理する。認可判定とは別に、明示した機能だけを有効にする。
module FeatureFlags
  KEYS = { demo_tenant: "FEATURE_DEMO_TENANT" }.freeze

  def self.enabled?(feature)
    ENV[KEYS.fetch(feature)] == "true"
  end

  def self.demo_mode?
    ENV["DEMO_MODE"] == "true"
  end
end
