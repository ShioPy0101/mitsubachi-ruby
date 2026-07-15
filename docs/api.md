# API Overview

このドキュメントは、現在の Rails 実装に合わせた API の概要です。

## 基本方針

- `drive_items` 系 API は認証必須です
- organization は URL ではなく `current_user.organization` から決まります
- 他 organization の `drive_item` は取得できず、通常は `404 Not Found` を返します
- ファイル本体の配信は `X-Accel-Redirect` を使い、Rails は認可とレスポンスヘッダー生成を担当します

## 認証 API

### `POST /auth/create`

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

### `POST /auth/login`

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

### `POST /auth/verify`

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

### `DELETE /logout`

ログアウト用の route は定義されています。

## Drive Items API

### 一覧・作成

### `GET /drive_items`

active なファイル・ディレクトリを一覧します。

クエリ:

- `parent_id`

主なレスポンス:

- `200 OK`
- `401 Unauthorized`

### `POST /drive_items`

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
- `422 Unprocessable Entity`

### 単体操作

### `GET /drive_items/:id`

active な 1 件を返します。

### `PATCH /drive_items/:id`

名前変更や親ディレクトリ変更を行います。

`parent_id` を指定する場合、移動先は同じ organization の active な directory である必要があります。

### `DELETE /drive_items/:id`

論理削除し、ゴミ箱へ移動します。

### `POST /drive_items/:id/restore`

論理削除済みアイテムを復元します。

主なレスポンス:

- `200 OK`
- `401 Unauthorized`
- `404 Not Found`
- `422 Unprocessable Entity`

### ゴミ箱・一括操作

### `GET /drive_items/trash`

論理削除済みアイテム一覧を返します。

### `POST /drive_items/bulk_move`

複数アイテムを指定ディレクトリへ移動します。

主な入力:

```json
{
  "drive_item_ids": [1, 2, 3],
  "parent_id": 10
}
```

### `POST /drive_items/bulk_delete`

複数アイテムをまとめて論理削除します。

### `POST /drive_items/bulk_restore`

複数アイテムをまとめて復元します。

### `POST /drive_items/bulk_download`

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

## 配信 API

以下は active なファイルのみを対象にします。

### `GET /drive_items/:id/preview`

- 用途: ブラウザ内表示
- `Content-Disposition: inline`

### `GET /drive_items/:id/download`

- 用途: ダウンロード
- `Content-Disposition: attachment`

### `GET /drive_items/:id/stream`

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
- 実ファイルが `storage/drive_items/:storage_key` に存在する必要があります
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

### `GET /up`

稼働確認用 endpoint です。成功時は `200 OK` と `ok` を返します。
