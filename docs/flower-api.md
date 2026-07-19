# Flower API

The flower API is the dedicated Mitsubachi entrypoint for After Effects integration. Its purpose is audit separation: requests enter `/api/v1/flower/*`, while authentication, authorization, tenant scoping, DriveItem lookup, and X-Accel-Redirect delivery reuse shared server logic.

## Authentication

Flower uses the existing Cookie session and magic link flow.

1. Fetch CSRF token: `GET /api/v1/flower/csrf_token`.
2. Request login link: `POST /api/v1/flower/auth/login`.
3. Verify login token: `POST /api/v1/flower/auth/verify`.
4. Use the returned Cookie session for flower API requests.
5. Logout: `DELETE /api/v1/flower/auth/logout`.

Successful flower verification regenerates the session and stores `session[:client_type] = "flower"` on the server. Normal Web login stores `web`, and flower protected endpoints reject non-flower sessions. Clients cannot set `client_type` with a request parameter or header.

The Cookie name is `_mitsubachi_ruby_session`. Production Cookie attributes are `Secure`, `HttpOnly`, and `SameSite=Lax`. CORS remains allowlist-based through `FRONTEND_ORIGIN` and credentials are allowed only for configured origins. The application does not disable CSRF globally or relax SameSite/HttpOnly/Secure for flower.

CEP behavior for Cookie persistence, CSRF token handling, and Origin allowlisting is not verified in code and must be tested on the target After Effects host, including Windows.

## Endpoints

`POST /api/v1/flower/auth/login`

Request:

```json
{ "email": "user@example.com" }
```

Response:

```json
{ "message": "認証リンクを送信しました" }
```

`POST /api/v1/flower/auth/verify`

Request:

```json
{ "token": "magic-link-token" }
```

Response:

```json
{
  "message": "ログインに成功しました",
  "user": { "id": 1, "email": "user@example.com", "display_name": "User One" }
}
```

`GET /api/v1/flower/me`

Requires a flower session. Returns the current user, organization, role, and `client_type`.

`GET /api/v1/flower/drive_items`

Query parameters: `parent_id`, `query`.

Response:

```json
{
  "items": [
    {
      "id": "21",
      "parent_id": null,
      "parent_name": null,
      "name": "IMG_1515",
      "extension": "mov",
      "display_name": "IMG_1515.mov",
      "item_type": "file",
      "content_type": "video/quicktime",
      "file_size": 46553959,
      "file_hash": "sha256:abcdef",
      "owner_user_id": 1,
      "owner_display_name": "未設定ユーザー",
      "created_at": "2026-07-17T08:35:29.009+09:00",
      "updated_at": "2026-07-17T08:35:29.009+09:00"
    }
  ]
}
```

Directories return `null` for `extension`, `content_type`, `file_size`, and `file_hash`. The API returns stored DB hashes and does not rehash files during listing.

`GET /api/v1/flower/drive_items/:id`

Returns one active DriveItem in the current organization. Tenant-boundary misses are `404`.

`GET /api/v1/flower/drive_items/:id/download`

Returns `X-Accel-Redirect`, `Content-Type`, and `Content-Disposition: attachment`. Rails does not stream the file body. Directories, deleted files, missing files, invalid storage keys, and tenant-boundary misses are rejected without returning storage internals.

`POST /api/v1/flower/drive_items/resolve`

Maximum request size is `100` items.

Request:

```json
{
  "items": [
    { "id": "21", "known_file_hash": "sha256:old" },
    { "id": "104", "known_file_hash": "sha256:current" }
  ]
}
```

Response statuses are `current`, `updated`, `deleted`, `not_found`, and `invalid`. `forbidden` is not exposed externally because tenant-boundary resources are intentionally indistinguishable from missing resources.

```json
{
  "items": [
    {
      "id": "21",
      "status": "updated",
      "file_hash": "sha256:new",
      "file_size": 46553959,
      "content_type": "video/quicktime",
      "updated_at": "2026-07-20T10:00:00.000+09:00"
    },
    {
      "id": "104",
      "status": "current",
      "file_hash": "sha256:current",
      "file_size": 651493,
      "content_type": "audio/mpeg",
      "updated_at": "2026-07-19T20:28:30.071+09:00"
    }
  ]
}
```

Duplicate IDs are preserved in response order so a client can map each request entry directly to a response entry.

## Errors

Protected flower APIs use the common API error object:

```json
{
  "error": {
    "code": "not_found",
    "message": "指定されたファイルが見つかりません",
    "details": {},
    "request_id": "..."
  }
}
```

Authentication failure responses do not expose whether the email or user exists. Request IDs are available in logs and response bodies according to the existing API error behavior.

## Audit Events

Flower writes dedicated `audit_events` actions and includes `metadata.client_type = "flower"`. Downloads also write `drive_item_access_logs` through the shared delivery service.

Recorded metadata may include DriveItem ID, stored file hash, file size, status, reason, request count, and status counts. Raw tokens, Cookie values, CSRF tokens, Authorization headers, secret URLs, local paths, and full email bodies must not be recorded.
