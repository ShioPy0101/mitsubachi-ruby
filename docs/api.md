# API Overview

このドキュメントは、現在の Rails 実装に合わせた API の概要です。

## 基本方針

- `drive_items` 系 API は認証必須です
- API は `/api/v1` 配下で公開します
- ヘルスチェックは `/api/health` 配下で公開します
- organization は URL ではなく `current_user.organization` から決まります
- 他 organization の `drive_item` は取得できず、通常は `404 Not Found` を返します
- ファイル本体の配信は `X-Accel-Redirect` を使い、Rails は認可とレスポンスヘッダー生成を担当します
- Rails は API 専用で、フロントエンドのビューやアセット配信は担当しません

## セッションとCSRF

認証は Devise の Cookie セッションを使います。フロントエンドは同一オリジンから相対パスで呼び出します。

```javascript
fetch("/api/v1/drive_items", {
  credentials: "same-origin"
})
```

本番の Cookie は `Secure`、`HttpOnly`、`SameSite=Lax` を前提にします。状態変更系 API では CSRF token を送信します。

### `GET /api/v1/csrf_token`

CSRF token を返します。

主なレスポンス:

```json
{
  "csrf_token": "..."
}
```

## 認証 API

### `POST /api/v1/auth/create`

招待コードを使った登録用のメール認証リンクを送信します。

主な入力:

```json
{
  "email": "user@example.com",
  "invite_code": "INVITE_CODE"
}
```

主なレスポンス:

- `200 OK`
- `400 Bad Request`
- `401 Unauthorized`
- `409 Conflict`

挙動:

- email は前後空白を除去し、小文字化して検索・保存します
- invite はトランザクション内でロックし、使用済み、有効期限、stand-by 状態を再確認します
- 同じ invite に active な stand-by がある間は、新しい登録リンクを発行しません
- stale な stand-by は解除してから仮ユーザーを再利用できます
- 本登録済みユーザーや、別 organization の通常ユーザーは、この API で organization を変更できません
- 登録用トークンの有効期限は 15 分で、同一 invite の古い未使用トークンは新しい発行時に使用済み扱いにします
- メール送信は DB トランザクションのコミット後にキューへ投入します

### `POST /api/v1/auth/login`

既存ユーザー向けのログイン用メール認証リンクを送信します。

主な入力:

```json
{
  "email": "user@example.com"
}
```

主なレスポンス:

- `200 OK`
- `400 Bad Request`
- `401 Unauthorized`

挙動:

- email は前後空白を除去し、小文字化して検索します
- 停止済みユーザー、存在しないユーザー、登録用リンク未検証の仮ユーザーにはログイン用リンクを発行しません
- ログイン用トークンの有効期限は 15 分で、同一メールアドレスの古い未使用ログイントークンは新しい発行時に使用済み扱いにします

### `POST /api/v1/auth/verify`

メール内のトークンを検証し、ログイン状態を作成します。

主な入力:

```json
{
  "token": "plain-token-from-email"
}
```

主なレスポンス:

- `200 OK`
- `400 Bad Request`
- `401 Unauthorized`

挙動:

- token は DB へ SHA-256 hash として保存され、メールに含まれる平文 token は保存しません
- token は単回使用です
- 検証時は `EmailAuthentication` をロックし、使用済み、有効期限、対象 User、停止状態を再確認します
- 登録用 token では OrganizationInvite もロックし、使用済み、有効期限、stand-by user との一致を再確認します
- token 発行後に User が停止された場合、セッションは作成せず、token は使用済み扱いにします
- invite と stand-by user が一致しない場合、invite は使用済みにしません

停止済みユーザーの既存 Cookie セッションは、認証必須 API の共通処理で拒否されます。logout は停止後も利用できます。

### `GET /api/v1/me`

現在のセッションで認証されているユーザーを返します。

主なレスポンス:

- `200 OK`
- `401 Unauthorized`

```json
{
  "data": {
    "id": 1,
    "organization_id": 1,
    "organization_name": "Example Organization",
    "email": "user@example.com",
    "name": "User Name",
    "role": "member",
    "suspended": false,
    "suspended_at": null,
    "last_sign_in_at": null,
    "created_at": "2026-07-16T00:00:00.000Z",
    "updated_at": "2026-07-16T00:00:00.000Z"
  }
}
```

### `DELETE /api/v1/logout`

現在のセッションを破棄します。

主なレスポンス:

- `204 No Content`

## Drive Items API

### 一覧・作成

### `GET /api/v1/drive_items`

active なファイル・ディレクトリを一覧します。

クエリ:

- `parent_id`

主なレスポンス:

- `200 OK`
- `401 Unauthorized`

### `POST /api/v1/drive_items`

ファイルまたはディレクトリを作成します。

主な入力:

```json
{
  "name": "report",
  "item_type": "file",
  "parent_id": 1
}
```

ファイル作成時は multipart で `file` を送ります。

制約:

- `item_type` は `file` または `directory`
- `file` 作成時はアップロードファイル必須
- `directory` 作成時はアップロードファイル指定不可
- `parent_id` を指定する場合、同じ organization の active な directory である必要があります
- 同一 `parent_id` 配下では、active な項目の `name` と `extension` の組み合わせは重複できません
- 保存時に `storage_key`、`blob_path`、`file_hash`、`file_size`、`content_type` を記録します

主なレスポンス:

- `201 Created`
- `401 Unauthorized`
- `404 Not Found`
- `413 Content Too Large`
- `422 Unprocessable Entity`

### 単体操作

### `GET /api/v1/drive_items/:id`

active な 1 件を返します。

### `PATCH /api/v1/drive_items/:id`

名前変更や親ディレクトリ変更を行います。

`parent_id` を指定する場合、移動先は同じ organization の active な directory である必要があります。

`PUT /api/v1/drive_items/:id` も同じ更新処理にルーティングされます。

### `DELETE /api/v1/drive_items/:id`

論理削除し、ゴミ箱へ移動します。

### `POST /api/v1/drive_items/:id/restore`

論理削除済みアイテムを復元します。

主なレスポンス:

- `200 OK`
- `401 Unauthorized`
- `404 Not Found`
- `422 Unprocessable Entity`

### ゴミ箱・一括操作

### `GET /api/v1/drive_items/trash`

論理削除済みアイテム一覧を返します。

### `POST /api/v1/drive_items/bulk_move`

複数アイテムを指定ディレクトリへ移動します。

主な入力:

```json
{
  "drive_item_ids": [1, 2, 3],
  "parent_id": 10
}
```

### `POST /api/v1/drive_items/bulk_delete`

複数アイテムをまとめて論理削除します。

### `POST /api/v1/drive_items/bulk_restore`

複数アイテムをまとめて復元します。

### `POST /api/v1/drive_items/bulk_download`

複数アイテムを ZIP 化してダウンロードします。

主な入力:

```json
{
  "drive_item_ids": [1, 2, 3]
}
```

挙動:

- 指定 ID は `current_user.organization.drive_items.active` から取得します
- directory が含まれる場合、その配下の active な file を再帰的に ZIP へ含めます
- ZIP 内のエントリ名はパス区切りや改行などを除去し、同名の場合は `(2)` 以降を付けて重複を避けます
- 同じ file が複数経路で指定された場合は 1 回だけ含めます
- 成功時は対象 file ごとに `bulk_download` の監査ログを記録します
- 一時 ZIP は `tmp/bulk_downloads` に作成し、レスポンス送信後に削除します

主なレスポンス:

- `200 OK`
- `401 Unauthorized`
- `404 Not Found`
- `422 Unprocessable Entity`

成功時の主なレスポンスヘッダー:

- `Content-Type: application/zip`
- `Content-Disposition: attachment`
- `Content-Length`

## 管理 API

管理 API は `/api/v1/admin` 配下で公開します。認証必須で、`member` は `403 Forbidden` になります。

role:

- `member`
- `organization_admin`
- `system_admin`

権限範囲:

- `system_admin` は全 organization の管理データを参照・更新できます
- `organization_admin` は自 organization の管理データだけを参照・更新できます
- テナント境界外のリソースは原則 `404 Not Found` を返します

一覧レスポンス:

```json
{
  "data": [],
  "meta": {
    "current_page": 1,
    "per_page": 20,
    "total_pages": 1,
    "total_count": 0
  }
}
```

エラーレスポンス:

```json
{
  "error": {
    "code": "forbidden",
    "message": "この操作を実行する権限がありません"
  }
}
```

### `GET /api/v1/admin/dashboard`

organization、user、drive_item、容量、直近 user / drive_item の集計を返します。`organization_admin` では自 organization の範囲に限定されます。

### Organization 管理

```text
GET   /api/v1/admin/organizations
GET   /api/v1/admin/organizations/:id
PATCH /api/v1/admin/organizations/:id
PUT   /api/v1/admin/organizations/:id
```

一覧クエリ:

- `page`
- `per_page` 最大 100
- `q` 名前検索
- `sort` は `created_at` / `name`
- `direction` は `asc` / `desc`

更新可能な属性:

- `name`

### User 管理

```text
GET   /api/v1/admin/users
GET   /api/v1/admin/users/:id
PATCH /api/v1/admin/users/:id
PUT   /api/v1/admin/users/:id
PATCH /api/v1/admin/users/:id/suspend
PATCH /api/v1/admin/users/:id/unsuspend
```

一覧クエリ:

- `page`
- `per_page` 最大 100
- `q` 名前またはメールアドレス検索
- `organization_id`
- `role`
- `status` は `active` / `suspended`
- `sort` は `created_at` / `last_sign_in_at` / `email` / `name`
- `direction` は `asc` / `desc`

制約:

- `organization_admin` は `system_admin` を変更できません
- `organization_admin` はユーザーを別 organization へ移動できません
- 最後の active な `system_admin` は降格・停止できません
- 停止は `suspended_at` による論理停止で、物理削除しません

### DriveItem 管理

```text
GET    /api/v1/admin/drive_items
GET    /api/v1/admin/drive_items/:id
DELETE /api/v1/admin/drive_items/:id
PATCH  /api/v1/admin/drive_items/:id/restore
```

一覧クエリ:

- `page`
- `per_page` 最大 100
- `q` ファイル名検索
- `organization_id`
- `user_id` 所有者 ID
- `item_type` は `file` / `directory`
- `content_type`
- `deleted` は `active` / `deleted` / `true` / `false`
- `sort` は `created_at` / `size` / `name`
- `direction` は `asc` / `desc`

管理 API の JSON レスポンスにファイル本体や実保存パスは含めません。削除・復元は `deleted_at` による既存の論理削除を使います。

### 管理監査ログ

```text
GET /api/v1/admin/audit_logs
GET /api/v1/admin/audit_logs/:id
```

記録対象:

- Organization 更新
- User 更新
- role 変更
- User 停止・停止解除
- DriveItem 削除・復元

一覧クエリ:

- `actor_user_id`
- `organization_id`
- `action`
- `target_type`
- `created_from`
- `created_to`

`organization_admin` は自 organization の管理監査ログだけを閲覧できます。

## 配信 API

以下は active なファイルのみを対象にします。

### `GET /api/v1/drive_items/:id/preview`

- 用途: ブラウザ内表示
- `Content-Disposition: inline`

### `GET /api/v1/drive_items/:id/download`

- 用途: ダウンロード
- `Content-Disposition: attachment`

### `GET /api/v1/drive_items/:id/stream`

- 用途: 動画などのシーク向け配信
- `Content-Disposition: inline`
- Range リクエストを想定

主なレスポンス:

- `200 OK`
- `401 Unauthorized`
- `404 Not Found`
- `503 Service Unavailable`

成功時の主なレスポンスヘッダー:

- `X-Accel-Redirect`
- `Content-Type`
- `Content-Disposition`

`X-Accel-Redirect` の内部 URI は次の形式です。

```text
/internal/storage/drive_items/:storage_key
```

配信前の検証:

- 対象は file である必要があります
- `storage_key` は `/`、`\`、`..`、NUL を含まない安全なキーである必要があります
- 実ファイルが `FILE_STORAGE_ROOT/drive_items/:storage_key` に存在する必要があります
- 認可とファイル検証の後、配信許可前に監査ログを記録します
- `stream` の監査ログは同一 user / file / organization について 5 分間重複記録を抑制します

## 主要データ構造

### `drive_items`

ファイルとディレクトリを同じテーブルで管理します。

主なカラム:

```text
id
organization_id
owner_user_id
parent_id
name
item_type
extension
storage_key
blob_path
content_type
file_hash
file_size
deleted_at
created_at
updated_at
```

補足:

- `item_type` は `file` / `directory`
- `deleted_at` が `NULL` のものを active として扱います
- ファイル保存先の内部識別子には `storage_key` を使います
- `blob_path` は `drive_items/:storage_key` 形式に同期されます
- 物理保存先のルートは `FILE_STORAGE_ROOT` で指定します。未指定時は既存互換のため `storage` を使います

### `drive_item_access_logs`

ファイル配信と一括ダウンロードの監査ログを管理します。

主なアクション:

```text
preview
download
stream
bulk_download
```

主なカラム:

```text
id
organization_id
user_id
drive_item_id
action
occurred_at
ip_address
user_agent
request_id
metadata
created_at
updated_at
```

## ヘルスチェック

### `GET /api/health`

DB 接続を含む ready check です。正常時は `200 OK` と `{ "status": "ok" }` を返します。DB 接続に失敗した場合は `503 Service Unavailable` と `{ "status": "unavailable" }` を返します。

### `GET /api/health/live`

プロセス生存確認です。DB 接続は確認せず、正常時は `200 OK` と `{ "status": "ok" }` を返します。

### `GET /api/health/ready`

DB 接続を含む ready check です。正常時は `200 OK` と `{ "status": "ok" }` を返します。DB 接続に失敗した場合は `503 Service Unavailable` と `{ "status": "unavailable" }` を返します。
