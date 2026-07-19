# Flower API

The flower API is the dedicated Mitsubachi boundary for After Effects integration. Flower does not reuse browser Cookie sessions for API access. It uses device authorization for browser approval and short-lived Bearer tokens for CEP/Node API calls.

## Authentication Boundary

Browser UI:

- Existing magic link login.
- Existing Cookie session.
- CSRF protection remains enabled.
- Device approval endpoints use this browser session.

Flower client:

- `POST /api/v1/flower/device_authorizations`
- `POST /api/v1/flower/tokens`
- `Authorization: Bearer <access_token>`
- CSRF is skipped only for non-Cookie flower client endpoints.
- Protected flower endpoints never fallback to Cookie auth and never accept query parameter tokens.

Access tokens are generated as cryptographic random values. Rails stores only SHA-256 digests in `flower_access_tokens.access_token_digest`. Device codes and user codes are also stored by digest only. Raw device codes, user codes, access tokens, refresh tokens, token digests, Authorization headers, Cookies, CSRF tokens, and internal paths must not be logged.

Initial PoC does not return refresh tokens. Access tokens expire after 15 minutes; expiry requires reauthorization. `flower_access_tokens.refresh_token_digest` exists for Phase 3 refresh-token rotation.

## Device Authorization

Request:

```http
POST /api/v1/flower/device_authorizations
```

```json
{
  "client_name": "mitsubachi-flower",
  "client_version": "0.1.0",
  "device_name": "After Effects 2022 on Windows"
}
```

Response:

```json
{
  "device_code": "secret-random-value",
  "user_code": "ABCD-EFGH",
  "verification_uri": "https://mitsubachi.shiosalt.com/flower/activate",
  "verification_uri_complete": "https://mitsubachi.shiosalt.com/flower/activate?user_code=ABCD-EFGH",
  "expires_in": 600,
  "interval": 5
}
```

`device_code` is never stored as plaintext. `user_code` uses uppercase non-confusing characters and is normalized by removing separators and case before digest lookup.

Device authorization statuses are `pending`, `approved`, `denied`, `consumed`, and `expired`.

## Browser Approval

The logged-in browser user opens:

```http
GET /flower/activate?user_code=ABCD-EFGH
```

The API-only implementation returns the current user's selectable organization list. The current data model allows one organization per user, so approval accepts only `current_user.organization_id`.

Approve:

```http
POST /api/v1/flower/device_authorizations/approve
```

```json
{
  "user_code": "ABCD-EFGH",
  "organization_id": "1"
}
```

Deny:

```http
POST /api/v1/flower/device_authorizations/deny
```

```json
{ "user_code": "ABCD-EFGH" }
```

Approval and denial use the existing Cookie session and CSRF protection. Suspended users, expired authorizations, consumed authorizations, denied authorizations, and non-owned organizations are rejected.

## Token Polling

```http
POST /api/v1/flower/tokens
```

```json
{
  "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
  "device_code": "..."
}
```

Possible error codes are `authorization_pending`, `slow_down`, `access_denied`, `expired_token`, and `invalid_grant`.

Success:

```json
{
  "token_type": "Bearer",
  "access_token": "...",
  "expires_in": 900,
  "scope": "flower:read flower:download",
  "organization_id": "1"
}
```

Polling interval is enforced per device authorization using `last_polled_at` and `interval_seconds` under row lock. Once a token is issued, the device authorization becomes `consumed` and cannot issue another token.

## Protected Endpoints

All protected requests require:

```http
Authorization: Bearer <access_token>
```

`GET /api/v1/flower/me`

```json
{
  "user": { "id": "1", "name": "User One" },
  "organization": { "id": "1", "name": "Team" },
  "scopes": ["flower:read", "flower:download"]
}
```

Email is intentionally not returned.

`GET /api/v1/flower/drive_items`

Query parameters: `parent_id`, `query`, `cursor`, `limit`. Limit is clamped to 1..100. Pagination is cursor-based over DriveItem IDs.

Only active image/video files in the token organization are returned. Directories, trashed items, other organizations, storage keys, blob paths, and internal paths are not returned.

Hash format:

```text
sha256:<64 lowercase hexadecimal characters>
```

If existing `drive_items.file_hash` is missing or not a 64-character SHA-256 hex value, `sha256` is returned as `null`. Listing never rehashes files.

`GET /api/v1/flower/drive_items/:id`

Returns one active image/video file with `download.available`.

`GET /api/v1/flower/drive_items/:id/download`

The selected strategy is A: flower sends Bearer token to Rails, Rails authenticates and authorizes, then returns `X-Accel-Redirect` so Nginx serves the file. Rails does not read the full file and does not use `send_data`.

Safe response headers:

- `X-Accel-Redirect`
- `Content-Type`
- `Content-Disposition`
- `ETag`
- `Accept-Ranges`
- `X-Mitsubachi-Drive-Item-Id`
- `X-Mitsubachi-File-Sha256`
- `X-Mitsubachi-Updated-At`
- `X-Request-Id`

`Content-Disposition` is generated by Rails helpers and strips CR/LF from filenames. `Content-Length` is not asserted by Rails unit tests because the Rails response body is empty for X-Accel-Redirect; Nginx integration must confirm the final file response length.

## Range Requests

Rails does not implement Range parsing. Range support is delegated to Nginx after `X-Accel-Redirect`.

Rails automated tests verify:

- Bearer auth is required.
- Organization boundary is enforced.
- Deleted items and directories are rejected.
- Download scope is required.
- X-Accel-Redirect and safe metadata headers are emitted.

Nginx integration tests must verify:

- No Range returns final `200`.
- `Range: bytes=0-0` returns final `206`.
- Unsatisfiable Range returns final `416`.
- Final `Content-Length` and `Content-Range` are correct.

AE/CEP real-device tests must separately verify token storage, network stack behavior, and download behavior on Windows.

## Errors

Flower API errors use:

```json
{
  "error": {
    "code": "authorization_pending",
    "message": "Authorization is still pending.",
    "request_id": "..."
  }
}
```

Known codes: `invalid_request`, `invalid_grant`, `authorization_pending`, `slow_down`, `access_denied`, `expired_token`, `invalid_token`, `insufficient_scope`, `not_found`, `conflict`, `rate_limited`, and `internal_error`.

## Rate Limit

- Device authorization creation: IP based, 20 requests per 10 minutes.
- Token polling: device authorization `interval_seconds`, initially 5 seconds.
- Download: token ID based, 120 requests per minute.

Rate limit keys never use plaintext access tokens.

## Audit Events

Events:

- `flower.device_authorization.created`
- `flower.authorization.approved`
- `flower.authorization.denied`
- `flower.token.issued`
- `flower.drive_item.listed`
- `flower.drive_item.viewed`
- `flower.file.downloaded`
- `flower.download.denied`

Metadata may include user ID through associations, organization ID, drive item ID, client version, device authorization ID, result, denial reason, downloaded bytes, request ID, IP address, and User-Agent through the recorder.

`flower.token.refreshed`, `flower.token.revoked`, refresh rotation, and reuse detection are Phase 3.
