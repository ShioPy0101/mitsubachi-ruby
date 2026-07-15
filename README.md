# Mitsubachi Rails API

Rails backend for the drive API. This repository is deployed as an API-only server; the frontend lives in a separate repository and process.

## Runtime

- Ruby: see `.ruby-version`
- Bundler: use the version bundled with the project lockfile
- Database: PostgreSQL
- Web server: Puma behind Caddy or Nginx
- Public origin: `https://drive.shiosalt.com/`
- API base path: `/api/v1`
- Health checks: `/api/health/live`, `/api/health/ready`

Rails should bind only to a private interface such as `127.0.0.1:3001`. Do not expose the Rails port directly to the internet.

## Required Environment

```text
APP_HOST=drive.shiosalt.com
FRONTEND_ORIGIN=http://localhost:3000
RAILS_MASTER_KEY=...
DATABASE_URL=postgres://...
FILE_STORAGE_ROOT=/srv/mitsubachi/files
MAX_UPLOAD_SIZE_BYTES=10737418240
RAILS_LOG_LEVEL=info
SECRET_KEY_BASE=...
RESEND_API_KEY=...
MAIL_FROM=...
FRONTEND_URL=https://drive.shiosalt.com
```

`FRONTEND_ORIGIN` is used only in development CORS. Production is same-origin and does not require CORS.

## Setup

```bash
bin/setup
bin/rails db:prepare
```

Create the file storage directory before starting Rails:

```bash
sudo mkdir -p /srv/mitsubachi/files/drive_items
sudo chown -R rails:rails /srv/mitsubachi/files
sudo chmod 750 /srv/mitsubachi/files /srv/mitsubachi/files/drive_items
```

Use the actual service user instead of `rails` if it differs.

## Run

Development:

```bash
bin/rails server -b 127.0.0.1 -p 3001
```

Production example:

```bash
RAILS_ENV=production bin/rails server -b 127.0.0.1 -p 3001
```

## Reverse Proxy Contract

- `/` is served by the frontend server.
- `/api/*` is proxied to Rails.
- The Rails internal port is not publicly reachable.
- Preserve the original `Host` header.
- Pass `X-Forwarded-Proto`.
- Configure upload limits at the proxy to be at least `MAX_UPLOAD_SIZE_BYTES`.
- Configure timeouts for large uploads and downloads.
- For protected file delivery, this Rails app currently emits `X-Accel-Redirect`; use Nginx or an equivalent internal delivery layer that supports that contract.

Minimal Nginx sketch:

```nginx
server {
  server_name drive.shiosalt.com;

  location /api/ {
    proxy_pass http://127.0.0.1:3001;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    client_max_body_size 10G;
  }

  location /internal/storage/ {
    internal;
    alias /srv/mitsubachi/files/;
  }

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
```

Caddy can terminate TLS and proxy `/api/*` to Rails, but `X-Accel-Redirect` is Nginx-specific. If Caddy is used as the public proxy, keep Nginx or another internal file delivery mechanism in front of protected storage.

## Security Notes

- Authentication uses Devise Cookie sessions.
- Production cookies are `Secure`, `HttpOnly`, and `SameSite=Lax`.
- Login verification regenerates the session.
- CSRF protection is enabled for state-changing requests; frontend clients should fetch `/api/v1/csrf_token` and send `X-CSRF-Token`.
- Production Host Authorization allows `APP_HOST` and does not clear host checks.
- `config.force_ssl` is enabled in production with reverse proxy TLS termination.
- File paths are derived from generated `storage_key` values, not user filenames.
- Content-Type is detected with Marcel and does not rely only on the client declaration.

## Tests

```bash
bin/ai-check
bin/check
```

## Backups

Back up PostgreSQL and `FILE_STORAGE_ROOT`. They must be restored together to keep DriveItem metadata and physical files consistent.

## Logs

Production logs go to STDOUT and include Rails request IDs. Do not log passwords, cookies, authorization headers, CSRF tokens, magic link tokens, or file contents.
