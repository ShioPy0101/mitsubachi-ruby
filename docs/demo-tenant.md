# デモ専用 API

デモは `User` や `Organization` の特別なレコードではなく、通常テナントと権限を共有しない
専用 API プロセスとして提供する。データは `Demo::Catalog` の合成カタログだけで、ファイルは作成しない。
DB migration、seed、実メール送信、実ファイル転送は追加しない。

## 有効化条件

- `DEMO_MODE=true`
- `FEATURE_DEMO_TENANT=true`
- Host が `mitsubachi-demo-api.shiosalt.com`
- POST の Origin が `https://demo.mitsubachi.shiosalt.com`

すべて満たした場合にだけ `/api/v1/demo/*` を公開する。未指定の feature flag は無効。
デモ用プロセスでは通常の ApplicationController 配下の API を404で拒否する。
health check は継続する。通常プロセスではデモ API を404にする。

## 認証と転送

| エンドポイント | 動作 |
| --- | --- |
| POST /api/v1/demo/login | 規定のメールアドレスだけを受け付け、未送信メールの宛先・件名・本文・URL を返す |
| POST /api/v1/demo/verify | 15分間有効・一回限りのリンクを消費し、8時間有効のデモ専用署名 token を返す |
| GET /api/v1/demo/items | Bearer token 検証後、表示専用のフォルダー・ファイル一覧を返す |
| POST /api/v1/demo/upload | デモ認証後も403で拒否する |
| POST /api/v1/demo/download | デモ認証後も403で拒否する |

認証リンクとアクセス token は、通常の magic link や Devise session と異なる purpose・verifier を使う。
通常のログイン API はデモ token を認証情報として利用しない。
リンクの nonce は Rails.cache に期限付きで保持し、delete の成否で一度だけ消費する。
デモの login は IP ごとに10分20回に制限する。すべての応答は `Cache-Control: no-store` とする。
ブラウザは Cookie を送らず、通常認証の Cookie・CSRF token も変更しない。

## 運用と分離

infra に専用 Nginx Host と systemd unit を追加している。
別環境ファイル、独立した SECRET_KEY_BASE、デモ専用の DB/cache 設定で起動する。
本番用環境ファイル・秘密情報・DB 接続先は転用しない。既存の本番設定は変更しない。
複数 worker に増やす場合も、リンクの発行・消費に共有 cache が必要。
起動に必要な既存設定と有効化・無効化手順は infra の `docs/demo-and-build-info.md` を参照する。

## ビルド情報

管理ダッシュボードの `data.build_info` に backend の component、Rails environment、
commit、built_at、deployed_at を追加した。管理者認可は既存のまま維持する。
`build-info.json` はビルド／リリースの成果物であり Git に含めない。
生成方法は README の Build metadata を参照する。
