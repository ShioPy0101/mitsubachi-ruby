# Audit Logs

Mitsubachi records two separate log streams.

- `audit_events`: important administration, authorization, and state-change events.
- `drive_item_access_logs`: file preview, download, stream, bulk download, and other delivery access records.

`AuditEvents::Recorder` captures `actor_user_id`, `organization_id`, action, target type / id, outcome, change set, metadata, request ID, IP address, User-Agent, and occurrence time. Recorder failures are logged and do not raise to the caller.

`AuditEvent` provides accountability for who changed which target and when. Examples include user suspension and restoration, organization setting changes, drive item deletion, restoration and movement, external share changes, permission changes, and system administrator operations. These records appear in the administrator "audit events" view.

`AuditLogs::Recorder` captures actual file access before protected delivery is allowed. It stores the user, organization, DriveItem, action, occurrence time, request ID, IP address, User-Agent, file metadata, client type, and access-path-specific metadata. Recorder failures make `DriveItems::DeliveryService` return `503`, so file delivery does not proceed without the required access log. These records are exposed separately through the administrator `file_access_logs` API for a "file access history" view.

Preview, stream, and download access is recorded only in `drive_item_access_logs`, not duplicated in `audit_events` or administrator operation logs. Stream access records are deduplicated within five minutes for the same organization, user, and drive item.

Organization administrators can list both log types for organizations where they have an active administrator membership. System administrators can list all organizations. Regular members cannot use either administrator log API. Both APIs scope records by `organization_id`; they do not narrow organization administrators to their own actor or user ID.

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
