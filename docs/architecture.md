# Architecture

## Test Framework
- Minitest
- Root: `test/`
- Helper: `test/test_helper.rb`

## Controllers
- `ApplicationController` - API 共通のベースコントローラ。Cookie セッションと CSRF 保護を有効にする
- `Api::HealthController` - reverse proxy やプロセス監視向けの live / ready check を扱う
- `Api::V1::DriveItemsController` - ドライブ項目の一覧、作成、移動、削除、復元、ファイル配信、一括ダウンロードを扱う
- `Api::V1::MeController` - 認証済みユーザー自身のプロフィール情報を返す
- `Api::V1::EmailAuthenticationsController` - メール認証リンクの発行と検証を扱う
- `Api::V1::Flower::DeviceAuthorizationsController` - flower device authorization の作成と状態参照を扱う
- `Api::V1::Flower::DeviceAuthorizationApprovalsController` - ログイン済みブラウザ session による approve / deny を扱う
- `Api::V1::Flower::TokensController` - device code から短命 Bearer token を発行する
- `Api::V1::Flower::DriveItemsController` - Bearer token 認証済み flower 向け read-only 一覧、詳細、download を扱う
- `Api::V1::Flower::MeController` - Bearer token 認証済み flower ユーザー情報を最小限返す
- `Flower::ActivationsController` - ブラウザで user code を承認するための activation entrypoint
- `Api::V1::CsrfTokensController` - 同一オリジン frontend が状態変更リクエスト前に使う CSRF token を返す
- `Api::V1::SessionsController` - logout を扱う
- `Api::V1::Admin::BaseController` - 管理 API 共通の認証、role 認可、テナント scope、ページネーション、エラーレスポンス、管理監査ログ記録を扱う
- `Api::V1::Admin::DashboardsController` - 管理画面ダッシュボード集計を扱う
- `Api::V1::Admin::OrganizationsController` - organization 管理を扱う
- `Api::V1::Admin::UsersController` - user 管理、role 変更、停止・停止解除を扱う
- `Api::V1::Admin::DriveItemsController` - drive item の管理用一覧、論理削除、復元を扱う
- `Api::V1::Admin::AuditLogsController` - 管理監査ログ閲覧を扱う

## API Boundary
- Rails は API 専用プロセスとして起動し、フロントエンドの view、Importmap、Turbo、Stimulus、asset 配信を担当しない
- 公開 API は `/api/v1` 配下、health check は `/api/health` 配下に置く
- 管理 API は通常ユーザー API と分離し、`/api/v1/admin` 配下に置く
- flower API は `/api/v1/flower` 配下に置き、After Effects 側は Bearer token のみで認証する。ブラウザ Cookie session への fallback はしない
- 本番は frontend の `https://drive.shiosalt.com/` から API の `https://mitsubachi-api.shiosalt.com/` を呼び出す別オリジン構成を前提とする
- API CORS は `FRONTEND_ORIGIN` の allowlist に一致する `Origin` のみ許可し、404 や認証エラーにも CORS ヘッダーを付与する
- Rails の内部ポートは `127.0.0.1:3001` などに bind し、インターネットへ直接公開しない
- ブラウザ API は Devise の Cookie セッションを使い、flower API は device authorization と短命 Bearer token を使う
- 本番 Cookie は `Secure`、`HttpOnly`、`SameSite=Lax` とする
- 停止済み User の既存 Cookie セッションは、認証必須 API の共通 before action で拒否する。logout は停止後も利用できるように除外する
- flower Bearer token は `Authorization` header だけから受け取り、query parameter token は拒否する

## Models
- `Organization` - ユーザー、招待、ドライブ項目を束ねる組織
- `User` - Devise 認証を持つ組織所属ユーザー
- `AdminAuditLog` - 管理操作の監査ログ
- `DriveItem` - ファイル/ディレクトリを表す階層オブジェクト
- `DrivePermission` - ユーザーとドライブ項目の権限付与
- `DriveItemAccessLog` - ドライブ項目アクセスの記録
- `OrganizationInvite` - 組織招待と stand-by 状態の管理
- `EmailAuthentication` - メール認証トークンと有効期限の管理
- `FlowerDeviceAuthorization` - device code / user code の digest、状態、有効期限、承認 user / organization を管理する
- `FlowerAccessToken` - flower Bearer token の digest、scope、有効期限、失効状態を管理する
- `ApplicationRecord` - Active Record 共通ベース

## Email Authentication
- 登録用リンク発行では、OrganizationInvite をトランザクション内でロックし、使用済み、有効期限、stand-by 状態をロック後に再検証する
- 登録用リンク発行時に作成または再利用する仮ユーザー、invite の stand-by 更新、EmailAuthentication 作成は同一トランザクションで行う
- メール送信は DB コミット後に Active Job へ投入し、ロールバックされた stand-by 状態のリンクを送らない
- active な stand-by は 15 分間有効とし、同一 invite の二重登録開始を拒否する。stale な stand-by は解除して再利用できる
- 本登録済み User と別 organization の通常 User は、登録 API から organization を変更できない
- ログイン用リンク発行では User をロック後に停止状態と仮登録状態を再検証する
- 新しいログイン用リンクを発行すると、同一メールアドレスの古い未使用かつ有効なログイントークンを使用済み扱いにする
- 新しい登録用リンクを発行すると、同一 invite の古い未使用かつ有効な登録トークンを使用済み扱いにする
- verify では EmailAuthentication をロック後、使用済み、有効期限、対象 User、停止状態を再検証する
- 登録用 verify では OrganizationInvite もロックし、使用済み、有効期限、stand-by user と認証対象 User の一致を再検証する
- User が token 発行後に停止された場合、セッションを作成せず、token は使用済み扱いにする
- token は SHA-256 hash を DB に保存し、平文 token はメール送信用にのみ扱う

## Flower API
- flower は After Effects 連携向けの専用 API 入口で、通常 Web API の Controller を直接使わない
- device authorization は `FlowerDeviceAuthorization` に digest のみ保存し、状態は `pending`、`approved`、`denied`、`consumed`、`expired` とする
- access token は `FlowerAccessToken` に SHA-256 digest のみ保存し、初期 PoC では 15 分の短命 token とする。refresh token rotation は Phase 3
- flower DriveItem 一覧と詳細は organization 起点の active file scope を使い、画像 / 動画だけを返す
- `/api/v1/flower/drive_items/:id/download` は `DriveItems::DeliveryService` を利用し、Rails から実ファイルを配信せず `X-Accel-Redirect` を返す
- CEP / Nginx / Range は Rails 自動テストとは分離して実機確認する

## Admin Authorization
- `User#role` は `member`、`organization_admin`、`system_admin` の enum
- `member` は管理 API を利用できない
- `system_admin` は全 organization の管理データを扱える
- `organization_admin` は `current_user.organization_id` を起点にした scope だけを扱える
- テナント境界外の管理リソースは存在推測を避けるため `404 Not Found` を返す
- `organization_admin` による `system_admin` 変更、別 organization への user 移動は禁止する
- 最後の active な `system_admin` の降格・停止は禁止する
- User 停止は `suspended_at` による論理停止で、Devise 認証時にも停止ユーザーを拒否する

## Admin Audit Logs
- 管理操作の監査ログは `admin_audit_logs` に保存する
- 対象操作は organization 更新、user 更新、role 変更、user 停止・停止解除、drive item 削除・復元
- 保存項目は actor user、organization、action、target type / id、change_set、IP、User-Agent
- パスワード、認証トークン、Cookie、生ファイル内容は保存しない

## Services
- `AuditLogs::Recorder` - preview / download / stream の監査ログ記録を集約する。動画の Range リクエストで `stream` ログが増え続けないよう、同一 organization / user / drive_item は 5 分間重複記録を抑制する
- `Auth::MagicLinks` - ブラウザ向け magic link 発行と検証の業務ロジックを集約する
- `DriveItems::Query` - organization 境界内の DriveItem 一覧、詳細、配信対象取得を集約する
- `Flower::DeviceAuthorizations::Create` - device code / user code の生成と digest 保存を扱う
- `Flower::DeviceAuthorizations::Approve` / `Deny` - ブラウザ session による承認状態遷移を扱う
- `Flower::Tokens::Exchange` / `Authenticate` - device code polling と Bearer token 認証を扱う
- `Flower::DriveItems::List` / `Show` - flower 用 read-only DriveItem 取得を扱う
- `Flower::Downloads::Authorize` - flower download scope と対象 DriveItem を検証する
- `DriveItems::DeliveryService` - 配信対象ファイルの検証、監査ログ記録、`X-Accel-Redirect` 用レスポンスヘッダー生成を担当する
- `DriveItems::BulkDownloadService` - 複数 drive_item から ZIP を作成し、directory 配下の active file を再帰的に含める
- `DriveItems::StoredFileInspector` - アップロードファイルを保存しながらサイズ、SHA-256、Content-Type を算出する
- `DriveItems::IntegrityChecker` - DB に記録されたサイズ、SHA-256、Content-Type と実ファイルの整合性を検査する

## Drive Item Storage
- 実ファイルは `FILE_STORAGE_ROOT/drive_items/:storage_key` に保存する。未指定時は既存互換のため `storage` を使う
- アップロードサイズ上限は `MAX_UPLOAD_SIZE_BYTES` で設定する。未指定時は 10 GiB とする
- アップロードは Rack の一時ファイルからチャンクコピーし、ファイル全体を Ruby のメモリへ読み込まない
- `storage_key` はファイル名として安全な文字だけを許可し、`/`、`\`、`..`、NUL を含む値は拒否する
- `DriveItem#blob_path` は `drive_items/:storage_key` 形式に同期する
- ディレクトリは `storage_key`、`blob_path`、`extension`、`file_hash` を持たない
- ファイルは `storage_key`、`blob_path`、`extension` を必須とする

## File Delivery
- Rails は認証、organization 境界での認可、対象ファイル検証、監査ログ、配信レスポンス生成を担当する
- 実ファイル転送は Nginx の `X-Accel-Redirect` に委譲する
- Caddy 単体では `X-Accel-Redirect` をそのまま使えないため、現構成では Nginx をファイル配信用 reverse proxy として利用する前提にする
- `preview` と `stream` は `Content-Disposition: inline`、`download` は `attachment` を返す
- `X-Accel-Redirect` の内部 URI は `DriveItem.storage_relative_path_for(storage_key)` から生成し、ユーザー入力を直接連結しない
- `storage_key` が不正、対象が directory、実ファイルが存在しない場合は配信しない
- Range Request は Rails では独自解析せず、内部リダイレクト先の Nginx に委譲する

## Bulk Download
- `Api::V1::DriveItemsController#bulk_download` は `DriveItems::BulkDownloadService` に ZIP 作成を委譲する
- 対象は `current_user.organization.drive_items.active` から取得し、他 organization の項目は含めない
- directory が指定された場合、配下の active file を再帰的に ZIP へ含める
- ZIP エントリ名は改行、NUL、パス区切り、`..` を避ける形に正規化する
- 同一 file は ZIP 内に重複して含めない
- 生成した一時 ZIP はレスポンス body の close 時、またはエラー時に削除する
- 成功時は ZIP に含めた file ごとに `bulk_download` の監査ログを記録する

## Mailers
- `ApplicationMailer` - 共通メーラーベース
- `EmailAuthenticationMailer` - 認証リンク送信

## Jobs
- `ApplicationJob` - Active Job 共通ベース
