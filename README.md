# UVdesk Community Helpdesk — Railway image

A production build of [uvdesk/community-skeleton](https://github.com/uvdesk/community-skeleton)
for [Railway](https://railway.com).

Upstream ships no container image. Its own `Dockerfile` installs Apache **and** a
MySQL server into a single Ubuntu box and ends on `CMD ["/bin/bash"]`, which is a
developer sandbox rather than a deployable service. This repository builds the same
PHP/Symfony application from an upstream release tarball, points it at an external
MySQL, serves it on `$PORT`, and completes the installation unattended so the
`/wizard` first-run screen is never exposed on a public URL.

## What the image does at boot

1. Renders the Apache vhost for Railway's `$PORT` and validates it with `configtest`.
2. Moves every mutable path onto the volume — uploaded assets, email attachments,
   PHP sessions, and the two config files the admin UI rewrites at runtime
   (`uvdesk.yaml`, `uvdesk_mailbox.yaml`).
3. Sets `uvdesk.site_url` from `RAILWAY_PUBLIC_DOMAIN`, rewriting only that line so
   website prefixes changed in the admin survive a redeploy.
4. Waits for MySQL, warms the Symfony cache, creates the schema and loads the
   fixtures on a fresh database, and seeds the first super admin.
5. Refuses to start Apache unless a privileged account exists, so the installation
   wizard is never reachable by a stranger.
6. Starts a mailbox poller that runs `uvdesk:refresh-mailbox` on the interval
   upstream documents as a cron entry. It no-ops until a mailbox is configured.

Steps 4–6 are idempotent: the migrate command only builds a schema when the database
has no tables, and the create-user command leaves an existing owner account alone.

## Variables

| Variable | Required | Default | Notes |
|---|---|---|---|
| `DATABASE_URL` | yes | — | `${{MySQL.MYSQL_URL}}` |
| `APP_SECRET` | yes | — | Symfony signing key; must stay stable |
| `UVDESK_ADMIN_EMAIL` | yes | — | first super admin |
| `UVDESK_ADMIN_PASSWORD` | yes | — | 8–32 characters |
| `UVDESK_ADMIN_NAME` | no | `Helpdesk Owner` | |
| `PORT` | no | `8080` | set by Railway |
| `UVDESK_SITE_URL` | no | `RAILWAY_PUBLIC_DOMAIN` | override for a custom domain |
| `UVDESK_MAILBOX_POLL_SECONDS` | no | `300` | `0` disables the poller |
| `UVDESK_DB_SERVER_VERSION` | no | `5.7` | Doctrine platform selector |
| `UV_SESSION_COOKIE_LIFETIME` | no | `86400` | seconds |
| `TRUSTED_PROXIES` | no | `0.0.0.0/0,::/0` | Railway's edge overwrites `X-Forwarded-For` |
| `UVDESK_REF` | no | `v1.1.8` | upstream git ref built by the image |

`UVDESK_REF` is a build argument as well as a variable, so changing it and
redeploying builds a different upstream release without editing this repo.

## Volume

One volume at `/data`, holding `assets/`, `attachments/`, `config/` and `sessions/`.
All four sit one level below the mount root so Railway's `lost+found` is never inside
a directory the application enumerates.

## Licence

The application is UVdesk Community, released by Webkul under the OSL-3.0 licence.
This repository only carries the packaging.
