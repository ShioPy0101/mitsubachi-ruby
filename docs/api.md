# Mitsubachi API List

> 作成元: アップロードされた Rails コントローラ  
> URL と HTTP メソッドは、提供された `config/routes.rb` に基づいて確定しています。

## 共通仕様

- API prefix: `/api`
- Versioned API prefix: `/api/v1`
- 認証方式: Devise の Cookie Session
- CSRF保護: 原則有効
- ログイン済みユーザーが停止状態の場合、セッションを破棄して `401 Unauthorized`
- 一般APIの代表的なエラー形式:

```json
{
  "error": "エラーメッセージ"
}
```

- 管理APIのエラー形式:

```json
{
  "error": {
    "code": "forbidden",
    "message": "この操作を実行する権限がありません",
    "details": {}
  }
}
```

- 管理APIのページネーション:

| パラメータ | 既定値 | 上限 |
| ---------- | -----: | ---: |
| `page`     |      1 | なし |
| `per_page` |     20 |  100 |

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

## 1. ヘルスチェック

### GET `/api/health`

`ready` と同じ処理を実行します。

認証: 不要  
CSRF: 不要

成功・失敗レスポンスは `/api/health/ready` と同一です。

### GET `/api/health/live`

プロセスが稼働しているか確認します。

認証: 不要  
CSRF: 不要

成功 `200 OK`:

```json
{
  "status": "ok"
}
```

### GET `/api/health/ready`

DB 接続を含め、リクエストを処理可能か確認します。

認証: 不要  
CSRF: 不要

成功 `200 OK`:

```json
{
  "status": "ok"
}
```

DB接続失敗 `503 Service Unavailable`:

```json
{
  "status": "unavailable"
}
```

## 2. CSRF

### GET `/api/v1/csrf_token`

CSRF token を取得します。

認証: 不要

成功 `200 OK`:

```json
{
  "csrf_token": "..."
}
```

> 実際のパスは `csrf_tokens#show` の routes 定義に依存します。

## 3. メール認証

### POST `/api/v1/auth/create`

招待コードを使用して、新規ユーザー向け認証リンクを送信します。

認証: 不要

リクエスト:

```json
{
  "email": "user@example.com",
  "invite_code": "INVITE_CODE"
}
```

成功 `200 OK`:

```json
{
  "message": "認証リンクを送信しました"
}
```

主なエラー:

- `400`: `email` または `invite_code` が未指定
- `401`: 招待コード不正、期限切れ、使用済み、ユーザー停止
- `409`: 招待コードまたはメールアドレスが検証中、登録済み

### POST `/api/v1/auth/login`

既存ユーザー向けログインリンクを送信します。

認証: 不要

リクエスト:

```json
{
  "email": "user@example.com"
}
```

成功 `200 OK`:

```json
{
  "message": "認証リンクを送信しました"
}
```

主なエラー:

- `400`: `email` 未指定
- `401`: ユーザー不存在、停止中、登録用メール認証が未完了

### POST `/api/v1/auth/verify`

メール内の token を検証し、セッションを開始します。

認証: 不要

リクエスト:

```json
{
  "token": "RAW_TOKEN"
}
```

成功 `200 OK`:

```json
{
  "message": "ログインに成功しました",
  "user": {
    "id": 1,
    "email": "user@example.com"
  }
}
```

主なエラー:

- `400`: token 未指定
- `401`: token 不正、使用済み、期限切れ、招待状態不正、ユーザー停止

認証 token の有効期限: 15分

## 4. セッション

### DELETE `/api/v1/logout`

現在のユーザーをログアウトさせます。

認証: 必須

成功 `204 No Content`

## 5. Drive Items

すべて認証必須です。対象は常に現在のユーザーと同じ organization に制限されます。

### GET `/api/v1/drive_items`

指定フォルダ直下の有効なファイル・ディレクトリを一覧表示します。

Query:

| 名前        | 必須 | 説明                         |
| ----------- | ---- | ---------------------------- |
| `parent_id` | 任意 | 未指定または空ならルート直下 |

成功 `200 OK`: DriveItem 配列

並び順:

1. `item_type DESC`
2. `name ASC`

### POST `/api/v1/drive_items`

ファイルまたはディレクトリを作成します。

Content-Type:

- ファイル: `multipart/form-data`
- ディレクトリ: JSON または form data

パラメータ:

| 名前        | 必須       | 説明                      |
| ----------- | ---------- | ------------------------- |
| `name`      | 必須相当   | 表示名                    |
| `item_type` | 必須       | `file` または `directory` |
| `parent_id` | 任意       | 親ディレクトリID          |
| `file`      | file時必須 | アップロードファイル      |

ファイル作成例:

```text
name=document
item_type=file
parent_id=10
file=<binary>
```

成功 `201 Created`: 作成された DriveItem

主なエラー:

- `404`: 親フォルダ不存在
- `413`: ファイルサイズ上限超過
- `422`: item_type 不正、file 未指定、ディレクトリ作成時に file 指定、親がファイル、同名重複、保存失敗

### GET `/api/v1/drive_items/:id`

有効な DriveItem を1件取得します。

成功 `200 OK`: DriveItem  
不存在 `404 Not Found`

### PATCH `/api/v1/drive_items/:id`

名前変更または移動を行います。

リクエスト:

```json
{
  "name": "new-name",
  "parent_id": 20
}
```

`parent_id: null` または空値でルート直下へ移動します。

成功 `200 OK`: 更新後の DriveItem

主なエラー:

- `404`: 対象または新しい親が不存在
- `422`: 新しい親がディレクトリではない、validation error

### DELETE `/api/v1/drive_items/:id`

DriveItem を論理削除し、ゴミ箱へ移動します。

成功 `200 OK`:

```json
{
  "message": "ファイルまたはフォルダをゴミ箱に移動しました"
}
```

### GET `/api/v1/drive_items/trash`

削除済み DriveItem を一覧表示します。

成功 `200 OK`: DriveItem 配列  
並び順: `deleted_at DESC`

### POST `/api/v1/drive_items/:id/restore`

削除済み DriveItem を復元します。

成功 `200 OK`: 復元後の DriveItem  
不存在 `404 Not Found`

### POST `/api/v1/drive_items/bulk_move`

複数の有効な DriveItem を移動します。

リクエスト:

```json
{
  "drive_item_ids": [1, 2, 3],
  "parent_id": 20
}
```

成功 `200 OK`:

```json
{
  "message": "ファイルまたはフォルダを移動しました"
}
```

### POST `/api/v1/drive_items/bulk_delete`

複数の有効な DriveItem をゴミ箱へ移動します。

リクエスト:

```json
{
  "drive_item_ids": [1, 2, 3]
}
```

成功 `200 OK`:

```json
{
  "message": "ファイルまたはフォルダをゴミ箱に移動しました"
}
```

### POST `/api/v1/drive_items/bulk_restore`

複数の削除済み DriveItem を復元します。

リクエスト:

```json
{
  "drive_item_ids": [1, 2, 3]
}
```

成功 `200 OK`:

```json
{
  "message": "ファイルまたはフォルダを復元しました"
}
```

### POST `/api/v1/drive_items/bulk_download`

複数の DriveItem を ZIP としてダウンロードします。

リクエスト:

```json
{
  "drive_item_ids": [1, 2, 3]
}
```

成功: ZIP binary

代表的なレスポンスヘッダー:

- `Content-Type: application/zip`
- `Content-Disposition: attachment; filename="..."`
- `Content-Length: ...`

### GET `/api/v1/drive_items/:id/preview`

ファイルをブラウザ表示向けに配信します。

成功時は DeliveryService が設定したヘッダーを返し、Rails 本体のレスポンスボディは空です。  
X-Accel-Redirect 等の内部配信を想定した構造です。

### GET `/api/v1/drive_items/:id/download`

ファイルを添付ファイルとして配信します。

成功時は DeliveryService が設定したステータス・ヘッダーを返します。

### GET `/api/v1/drive_items/:id/stream`

Range request 等を想定したストリーミング配信です。

成功時は DeliveryService が設定したステータス・ヘッダーを返します。

## 6. 管理API共通

Prefix: `/api/v1/admin`

認証: 必須  
権限: `system_admin` または `organization_admin`

権限範囲:

| 権限                 | 参照可能範囲         |
| -------------------- | -------------------- |
| `system_admin`       | 全 organization      |
| `organization_admin` | 自 organization のみ |

一覧APIの共通 Query:

| 名前        | 説明                                 |
| ----------- | ------------------------------------ |
| `page`      | ページ番号、既定1                    |
| `per_page`  | 1ページ件数、既定20、最大100         |
| `direction` | `asc` の場合のみ昇順。それ以外は降順 |

## 7. 管理ダッシュボード

### GET `/api/v1/admin/dashboard`

管理画面の集計値と最新データを取得します。

成功 `200 OK`:

```json
{
  "data": {
    "organizations_count": 1,
    "users_count": 10,
    "active_users_count": 9,
    "drive_items_count": 100,
    "files_count": 80,
    "directories_count": 20,
    "total_storage_bytes": 123456789,
    "recent_users": [],
    "recent_drive_items": []
  }
}
```

## 8. 管理 Organization API

### GET `/api/v1/admin/organizations`

Query:

| 名前        | 説明                       |
| ----------- | -------------------------- |
| `q`         | organization名の部分一致   |
| `sort`      | `created_at` または `name` |
| `direction` | `asc` または降順           |

成功 `200 OK`: `data` と `meta`

### GET `/api/v1/admin/organizations/:id`

成功 `200 OK`:

```json
{
  "data": {
    "id": 1,
    "name": "Example",
    "users_count": 10,
    "drive_items_count": 100,
    "storage_bytes": 123456,
    "created_at": "...",
    "updated_at": "..."
  }
}
```

### PATCH `/api/v1/admin/organizations/:id`

リクエスト:

```json
{
  "organization": {
    "name": "New Name"
  }
}
```

成功 `200 OK`: 更新後 organization  
監査ログ action: `organization.update`

## 9. 管理 User API

### GET `/api/v1/admin/users`

Query:

| 名前              | 説明                                             |
| ----------------- | ------------------------------------------------ |
| `q`               | name または email の部分一致                     |
| `organization_id` | system_admin のみ有効                            |
| `role`            | User enum に存在する role                        |
| `status`          | `active` または `suspended`                      |
| `sort`            | `created_at`, `last_sign_in_at`, `email`, `name` |
| `direction`       | `asc` または降順                                 |

### GET `/api/v1/admin/users/:id`

成功 `200 OK`: user data

### PATCH `/api/v1/admin/users/:id`

リクエスト:

```json
{
  "user": {
    "name": "User Name",
    "email": "user@example.com",
    "role": "organization_admin",
    "organization_id": 1
  }
}
```

制約:

- organization_admin は system_admin を変更不可
- organization_admin はユーザーを別 organization へ移動不可
- 最後の active system_admin は降格不可
- 自 organization の最後の organization_admin が不在になる変更は不可
- `organization_id` の変更は system_admin のみ

監査ログ action:

- role変更時: `user.role_change`
- その他: `user.update`

### PATCH `/api/v1/admin/users/:id/suspend`

ユーザーを停止します。

成功 `200 OK`: 更新後 user  
監査ログ action: `user.suspend`

最後の active system_admin は停止できません。

### PATCH `/api/v1/admin/users/:id/unsuspend`

ユーザー停止を解除します。

成功 `200 OK`: 更新後 user  
監査ログ action: `user.unsuspend`

## 10. 管理 DriveItem API

### GET `/api/v1/admin/drive_items`

Query:

| 名前              | 説明                                 |
| ----------------- | ------------------------------------ |
| `q`               | name 部分一致                        |
| `organization_id` | system_admin のみ有効                |
| `user_id`         | owner_user_id                        |
| `item_type`       | DriveItem enum に存在する値          |
| `content_type`    | 完全一致                             |
| `deleted`         | `true`, `deleted`, `false`, `active` |
| `sort`            | `created_at`, `size`, `name`         |
| `direction`       | `asc` または降順                     |

### GET `/api/v1/admin/drive_items/:id`

成功 `200 OK`: DriveItem data

### DELETE `/api/v1/admin/drive_items/:id`

DriveItem を論理削除します。

成功 `200 OK`: 更新後 DriveItem  
監査ログ action: `drive_item.delete`

### PATCH `/api/v1/admin/drive_items/:id/restore`

DriveItem を復元します。

成功 `200 OK`: 更新後 DriveItem  
監査ログ action: `drive_item.restore`

## 11. 管理監査ログ API

### GET `/api/v1/admin/audit_logs`

Query:

| 名前              | 説明                  |
| ----------------- | --------------------- |
| `actor_user_id`   | 操作者ユーザーID      |
| `organization_id` | system_admin のみ有効 |
| `action`          | action 完全一致       |
| `target_type`     | 対象モデル名          |
| `created_from`    | 開始日時              |
| `created_to`      | 終了日時              |
| `page`            | ページ番号            |
| `per_page`        | 1ページ件数           |

日時の解釈に失敗した場合は、例外ではなく空一覧になります。

### GET `/api/v1/admin/audit_logs/:id`

成功 `200 OK`:

```json
{
  "data": {
    "id": 1,
    "actor_user_id": 1,
    "actor_email": "admin@example.com",
    "organization_id": 1,
    "organization_name": "Example",
    "action": "user.update",
    "target_type": "User",
    "target_id": 10,
    "change_set": {},
    "ip_address": "127.0.0.1",
    "user_agent": "...",
    "created_at": "..."
  }
}
```

## 12. ルート一覧（確定）

| Method    | Path                                    | Controller#Action                     |
| --------- | --------------------------------------- | ------------------------------------- |
| GET       | `/api/health`                           | `api/health#ready`                    |
| GET       | `/api/health/live`                      | `api/health#live`                     |
| GET       | `/api/health/ready`                     | `api/health#ready`                    |
| GET       | `/api/v1/csrf_token`                    | `api/v1/csrf_tokens#show`             |
| GET       | `/api/v1/admin/dashboard`               | `api/v1/admin/dashboards#show`        |
| GET       | `/api/v1/admin/organizations`           | `api/v1/admin/organizations#index`    |
| GET       | `/api/v1/admin/organizations/:id`       | `api/v1/admin/organizations#show`     |
| PATCH/PUT | `/api/v1/admin/organizations/:id`       | `api/v1/admin/organizations#update`   |
| GET       | `/api/v1/admin/users`                   | `api/v1/admin/users#index`            |
| GET       | `/api/v1/admin/users/:id`               | `api/v1/admin/users#show`             |
| PATCH/PUT | `/api/v1/admin/users/:id`               | `api/v1/admin/users#update`           |
| PATCH     | `/api/v1/admin/users/:id/suspend`       | `api/v1/admin/users#suspend`          |
| PATCH     | `/api/v1/admin/users/:id/unsuspend`     | `api/v1/admin/users#unsuspend`        |
| GET       | `/api/v1/admin/drive_items`             | `api/v1/admin/drive_items#index`      |
| GET       | `/api/v1/admin/drive_items/:id`         | `api/v1/admin/drive_items#show`       |
| DELETE    | `/api/v1/admin/drive_items/:id`         | `api/v1/admin/drive_items#destroy`    |
| PATCH     | `/api/v1/admin/drive_items/:id/restore` | `api/v1/admin/drive_items#restore`    |
| GET       | `/api/v1/admin/audit_logs`              | `api/v1/admin/audit_logs#index`       |
| GET       | `/api/v1/admin/audit_logs/:id`          | `api/v1/admin/audit_logs#show`        |
| POST      | `/api/v1/auth/create`                   | `api/v1/email_authentications#create` |
| POST      | `/api/v1/auth/login`                    | `api/v1/email_authentications#login`  |
| POST      | `/api/v1/auth/verify`                   | `api/v1/email_authentications#verify` |
| DELETE    | `/api/v1/logout`                        | `api/v1/sessions#destroy`             |
| GET       | `/api/v1/drive_items`                   | `api/v1/drive_items#index`            |
| POST      | `/api/v1/drive_items`                   | `api/v1/drive_items#create`           |
| GET       | `/api/v1/drive_items/:id`               | `api/v1/drive_items#show`             |
| PATCH/PUT | `/api/v1/drive_items/:id`               | `api/v1/drive_items#update`           |
| DELETE    | `/api/v1/drive_items/:id`               | `api/v1/drive_items#destroy`          |
| GET       | `/api/v1/drive_items/trash`             | `api/v1/drive_items#trash`            |
| POST      | `/api/v1/drive_items/bulk_move`         | `api/v1/drive_items#bulk_move`        |
| POST      | `/api/v1/drive_items/bulk_delete`       | `api/v1/drive_items#bulk_delete`      |
| POST      | `/api/v1/drive_items/bulk_restore`      | `api/v1/drive_items#bulk_restore`     |
| POST      | `/api/v1/drive_items/bulk_download`     | `api/v1/drive_items#bulk_download`    |
| GET       | `/api/v1/drive_items/:id/preview`       | `api/v1/drive_items#preview`          |
| GET       | `/api/v1/drive_items/:id/download`      | `api/v1/drive_items#download`         |
| GET       | `/api/v1/drive_items/:id/stream`        | `api/v1/drive_items#stream`           |
| POST      | `/api/v1/drive_items/:id/restore`       | `api/v1/drive_items#restore`          |

> `resources :drive_items` には標準の `new` と `edit` ルートも生成されますが、APIコントローラに対応アクションがない場合は実用対象外です。API専用なら `only:` で明示的に制限する方が安全。
