require "json"

module Deployment
  # デプロイ時に書き込んだ不変の情報を返す。起動時刻をビルド時刻と取り違えず、
  # 情報がないリリースは nil として管理画面で「未記録」と表示する。
  class BuildInfo
    def self.read(path: Rails.root.join("build-info.json"), env: ENV)
      artifact = path.file? ? JSON.parse(path.read).slice("commit", "built_at", "deployed_at") : {}
      {
        component: "backend",
        environment: Rails.env.to_s,
        commit: artifact["commit"].presence || env["GIT_COMMIT_SHA"].presence,
        built_at: artifact["built_at"].presence || env["BUILD_TIMESTAMP"].presence,
        deployed_at: artifact["deployed_at"].presence || env["DEPLOYED_AT"].presence
      }
    rescue JSON::ParserError
      { component: "backend", environment: Rails.env.to_s, commit: nil, built_at: nil, deployed_at: nil }
    end
  end
end
