# Architecture

## Test Framework
- Minitest
- Root: `test/`
- Helper: `test/test_helper.rb`

## Controllers
- `ApplicationController` - API 共通のベースコントローラ
- `DriveItemsController` - ドライブ項目の一覧、作成、移動、削除、復元、ファイル配信、一括ダウンロードを扱う
- `EmailAuthenticationsController` - メール認証リンクの発行と検証を扱う

## Models
- `Organization` - ユーザー、招待、ドライブ項目を束ねる組織
- `User` - Devise 認証を持つ組織所属ユーザー
- `DriveItem` - ファイル/ディレクトリを表す階層オブジェクト
- `DrivePermission` - ユーザーとドライブ項目の権限付与
- `DriveItemAccessLog` - ドライブ項目アクセスの記録
- `OrganizationInvite` - 組織招待と stand-by 状態の管理
- `EmailAuthentication` - メール認証トークンと有効期限の管理
- `ApplicationRecord` - Active Record 共通ベース

## Services
- `AuditLogs::Recorder` - preview / download / stream の監査ログ記録を集約する。動画の Range リクエストで `stream` ログが増え続けないよう、同一 organization / user / drive_item は 5 分間重複記録を抑制する
- `DriveItems::DeliveryService` - 配信対象ファイルの検証、監査ログ記録、`X-Accel-Redirect` 用レスポンスヘッダー生成を担当する
- `DriveItems::BulkDownloadService` - 複数 drive_item から ZIP を作成し、directory 配下の active file を再帰的に含める
- `DriveItems::StoredFileInspector` - アップロードファイルを保存しながらサイズ、SHA-256、Content-Type を算出する
- `DriveItems::IntegrityChecker` - DB に記録されたサイズ、SHA-256、Content-Type と実ファイルの整合性を検査する

## Drive Item Storage
- 実ファイルは `storage/drive_items/:storage_key` に保存する
- `storage_key` はファイル名として安全な文字だけを許可し、`/`、`\`、`..`、NUL を含む値は拒否する
- `DriveItem#blob_path` は `drive_items/:storage_key` 形式に同期する
- ディレクトリは `storage_key`、`blob_path`、`extension`、`file_hash` を持たない
- ファイルは `storage_key`、`blob_path`、`extension` を必須とする

## File Delivery
- Rails は認証、organization 境界での認可、対象ファイル検証、監査ログ、配信レスポンス生成を担当する
- 実ファイル転送は Nginx の `X-Accel-Redirect` に委譲する
- `preview` と `stream` は `Content-Disposition: inline`、`download` は `attachment` を返す
- `X-Accel-Redirect` の内部 URI は `DriveItem.storage_relative_path_for(storage_key)` から生成し、ユーザー入力を直接連結しない
- `storage_key` が不正、対象が directory、実ファイルが存在しない場合は配信しない

## Bulk Download
- `DriveItemsController#bulk_download` は `DriveItems::BulkDownloadService` に ZIP 作成を委譲する
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
