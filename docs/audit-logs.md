# Audit Logs

Mitsubachi records two audit streams.

- `audit_events`: authentication, administration, drive item mutations, preview starts, flower entrypoint events.
- `drive_item_access_logs`: file preview / download / stream / bulk download access records.

`AuditEvents::Recorder` captures `actor_user_id`, `organization_id`, action, target type / id, outcome, change set, metadata, request ID, IP address, User-Agent, and occurrence time. Recorder failures are logged and do not raise to the caller.

`AuditLogs::Recorder` captures file access events before protected delivery is allowed. Recorder failures make `DriveItems::DeliveryService` return `503`, so file delivery does not proceed without the required access log.

An authenticated preview also records one `drive_item.preview` event before Rails returns `X-Accel-Redirect`. Subsequent video or audio Range requests use the `stream` endpoint and do not create additional preview events. Stream access records are deduplicated within five minutes for the same organization, user, and drive item.

Organization administrators can list all `audit_events` belonging to organizations where they have an active administrator membership. The scope is based on `organization_id`, not `actor_user_id`, so events by other users in the same organization are visible while events from other organizations remain excluded. Regular members cannot use the administrator audit event API; there is no separate regular-member audit history API in this Rails application.

Flower events use `metadata.client_type = "flower"` and dedicated action names:

- `flower.device_authorization.created`
- `flower.authorization.approved`
- `flower.authorization.denied`
- `flower.token.issued`
- `flower.drive_item.listed`
- `flower.drive_item.viewed`
- `flower.file.downloaded`
- `flower.download.denied`

Do not record raw magic link tokens, device codes, user codes, access tokens, refresh tokens, token digests, session cookies, CSRF tokens, Authorization headers, secret download URLs, local storage paths, or full email bodies. File access metadata may include `file_hash`, `file_size`, `content_type`, and `client_type`, but not `storage_key`.

Tenant-boundary denials are returned to clients as `not_found`. Internal audit metadata may record `reason: "not_found"` for denied flower downloads without exposing whether the ID existed in another organization.
