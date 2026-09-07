#!/bin/bash
# UVdesk on Railway - boot-time setup.
#
# Everything the shipped /wizard would do interactively is done here instead:
# render Apache for $PORT, put mutable state on the volume, wait for MySQL,
# create the schema, load the fixtures, and seed the first super admin. The
# wizard is therefore never reachable on a fresh deployment, which is what
# stops a stranger claiming the owner account on a public URL.
set -euo pipefail

log() { printf '[uvdesk-entrypoint] %s\n' "$*"; }
fail() { printf '[uvdesk-entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

HOME_DIR="${UVDESK_HOME:-/var/www/uvdesk}"
DATA_DIR="${UVDESK_DATA:-/data}"
RUN_USER="www-data"
CONSOLE=(php "$HOME_DIR/bin/console")

# ---------------------------------------------------------------------------
# Ports and Apache
# ---------------------------------------------------------------------------
PORT="${PORT:-8080}"
case "$PORT" in
    ''|*[!0-9]*) fail "PORT is not a number: '$PORT'" ;;
esac
export PORT

printf 'Listen %s\n' "$PORT" > /etc/apache2/ports.conf
sed "s/__PORT__/${PORT}/g" /opt/uvdesk-railway/apache/uvdesk.conf \
    > /etc/apache2/sites-available/000-default.conf

if grep -q '__[A-Z_]\{2,\}__' /etc/apache2/sites-available/000-default.conf; then
    fail "unsubstituted placeholder left in the rendered Apache config"
fi

# php:8.x-apache images have shipped with mpm_event and mpm_prefork both
# enabled, which mod_php refuses to start under. Correcting it here rather than
# in a build layer, because the enabled set is re-read at container start.
if [ -e /etc/apache2/mods-enabled/mpm_event.load ] || [ -e /etc/apache2/mods-enabled/mpm_worker.load ]; then
    log "disabling extra MPMs so mod_php's mpm_prefork is the only one loaded"
    rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
    a2enmod mpm_prefork >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Volume layout. Everything mutable lives one level below the mount root, so
# Railway's lost+found is never inside a directory the app enumerates.
# ---------------------------------------------------------------------------
export UVDESK_SESSION_SAVE_PATH="${UVDESK_SESSION_SAVE_PATH:-$DATA_DIR/sessions}"

mkdir -p "$DATA_DIR/assets" "$DATA_DIR/attachments" "$DATA_DIR/config" "$UVDESK_SESSION_SAVE_PATH"

link_to_volume() {
    local target="$1" link="$2"
    if [ -L "$link" ]; then
        return 0
    fi
    if [ -d "$link" ]; then
        # Seed anything the image shipped in that directory, then replace it.
        find "$link" -mindepth 1 -maxdepth 1 -exec cp -rn {} "$target/" \; 2>/dev/null || true
        rm -rf "$link"
    fi
    ln -sfn "$target" "$link"
}

# Symfony leaves session.save_path null, so PHP falls back to /tmp - which the
# container throws away on every deploy. Point it at the volume instead.
printf 'session.save_path = "%s"\n' "$UVDESK_SESSION_SAVE_PATH" \
    > "${PHP_INI_DIR:-/usr/local/etc/php}/conf.d/zzz-uvdesk-session.ini"

link_to_volume "$DATA_DIR/assets" "$HOME_DIR/public/assets"
link_to_volume "$DATA_DIR/attachments" "$HOME_DIR/public/attachments"

# The admin UI writes both of these config files at runtime - website prefixes
# and the whole mailbox/SMTP configuration - so they are mutable state and
# belong on the volume, not in the image layer.
for cfg in uvdesk.yaml uvdesk_mailbox.yaml; do
    if [ ! -f "$DATA_DIR/config/$cfg" ]; then
        if [ -L "$HOME_DIR/config/packages/$cfg" ]; then
            fail "config/packages/$cfg is a dangling symlink and the volume has no copy"
        fi
        cp "$HOME_DIR/config/packages/$cfg" "$DATA_DIR/config/$cfg"
        log "seeded $cfg onto the volume"
    fi
    ln -sfn "$DATA_DIR/config/$cfg" "$HOME_DIR/config/packages/$cfg"
done

# ---------------------------------------------------------------------------
# Public URL. uvdesk.site_url is the host every emailed ticket link and the
# mailbox listener endpoint are built from, so it has to track the domain the
# deployment actually answers on. Only that one line is rewritten, leaving any
# prefix an operator has since changed in the admin UI alone.
# ---------------------------------------------------------------------------
SITE_URL="${UVDESK_SITE_URL:-${RAILWAY_PUBLIC_DOMAIN:-}}"
SITE_URL="${SITE_URL#https://}"
SITE_URL="${SITE_URL#http://}"
SITE_URL="${SITE_URL%/}"

if [ -n "$SITE_URL" ]; then
    CURRENT_SITE_URL="$(sed -n "s/^[[:space:]]*site_url:[[:space:]]*'\{0,1\}\([^'#]*\)'\{0,1\}[[:space:]]*$/\1/p" \
        "$DATA_DIR/config/uvdesk.yaml" | head -n1 | tr -d '[:space:]')"
    if [ "$CURRENT_SITE_URL" != "$SITE_URL" ]; then
        sed -i "s|^\([[:space:]]*\)site_url:.*$|\1site_url: '${SITE_URL}'|" "$DATA_DIR/config/uvdesk.yaml"
        log "site_url set to $SITE_URL"
    fi
else
    log "no public domain in the environment - leaving site_url as it is"
fi

grep -q "site_url:" "$DATA_DIR/config/uvdesk.yaml" || fail "site_url disappeared from uvdesk.yaml"

# ---------------------------------------------------------------------------
# Ownership. Apache drops to www-data, and the console commands below run as
# that same user so nothing root-owned is left in var/ or on the volume.
# ---------------------------------------------------------------------------
chown -R "$RUN_USER:$RUN_USER" "$DATA_DIR" "$HOME_DIR/var" 2>/dev/null || true
chown -h "$RUN_USER:$RUN_USER" "$HOME_DIR/public/assets" "$HOME_DIR/public/attachments" 2>/dev/null || true
chown -h "$RUN_USER:$RUN_USER" "$HOME_DIR/config/packages/uvdesk.yaml" "$HOME_DIR/config/packages/uvdesk_mailbox.yaml" 2>/dev/null || true

as_app() { gosu_run "$@"; }
gosu_run() { setpriv --reuid="$(id -u $RUN_USER)" --regid="$(id -g $RUN_USER)" --init-groups env HOME=/tmp "$@"; }

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
if [ -z "${DATABASE_URL:-}" ] || [ "${DATABASE_URL}" = "mysql://db_user:db_password@127.0.0.1:3306/db_name" ]; then
    fail "DATABASE_URL is not set. Reference the MySQL service, e.g. \${{MySQL.MYSQL_URL}}"
fi

log "waiting for the database"
DB_READY=0
for _ in $(seq 1 60); do
    if php /opt/uvdesk-railway/bin/db-wait.php >/dev/null 2>&1; then
        DB_READY=1
        break
    fi
    sleep 5
done
[ "$DB_READY" = "1" ] || fail "database did not become reachable within 5 minutes"
log "database is reachable"

# ---------------------------------------------------------------------------
# Symfony cache. Built here rather than at image build time because the
# container is rebuilt on every deploy and uvdesk.yaml only settles above.
# ---------------------------------------------------------------------------
rm -rf "$HOME_DIR/var/cache"
mkdir -p "$HOME_DIR/var/cache" "$HOME_DIR/var/log"
chown -R "$RUN_USER:$RUN_USER" "$HOME_DIR/var"
as_app "${CONSOLE[@]}" cache:warmup --no-interaction >/dev/null

log "symfony cache warmed for APP_ENV=${APP_ENV:-prod}; sessions on $UVDESK_SESSION_SAVE_PATH"

# ---------------------------------------------------------------------------
# Schema, fixtures and the first super admin. All three are idempotent: the
# migrate command only creates a schema when the database has no tables, and
# create-user exits 1 when a super admin already exists rather than replacing
# an operator's password.
# ---------------------------------------------------------------------------
log "running database setup"
as_app "${CONSOLE[@]}" uvdesk_wizard:database:migrate --no-interaction

if [ -n "${UVDESK_ADMIN_EMAIL:-}" ] && [ -n "${UVDESK_ADMIN_PASSWORD:-}" ]; then
    if as_app "${CONSOLE[@]}" uvdesk_wizard:defaults:create-user \
        ROLE_SUPER_ADMIN "${UVDESK_ADMIN_NAME:-Helpdesk Owner}" \
        "$UVDESK_ADMIN_EMAIL" "$UVDESK_ADMIN_PASSWORD" --no-interaction; then
        log "super admin $UVDESK_ADMIN_EMAIL created"
    else
        log "a super admin already exists - leaving the existing account alone"
    fi
else
    log "UVDESK_ADMIN_EMAIL/UVDESK_ADMIN_PASSWORD unset - no admin seeded"
fi

# Fail closed: a helpdesk with no super admin serves the installation wizard to
# the internet, and whoever reaches it first owns the deployment.
if ! php /opt/uvdesk-railway/bin/assert-installed.php; then
    fail "no super admin account exists - refusing to serve the installation wizard on a public URL. Set UVDESK_ADMIN_EMAIL and UVDESK_ADMIN_PASSWORD and redeploy."
fi
log "installation verified: schema present and a super admin exists"

# ---------------------------------------------------------------------------
# Mailbox polling. Upstream documents a cron running uvdesk:refresh-mailbox to
# turn incoming email into tickets; Railway volumes are 1:1, so the mailbox
# configuration the admin UI writes is only readable from this container and
# the poller has to live beside it. It no-ops until a mailbox is configured.
# ---------------------------------------------------------------------------
if [ "${UVDESK_MAILBOX_POLL_SECONDS:-300}" -gt 0 ] 2>/dev/null; then
    log "starting mailbox poller every ${UVDESK_MAILBOX_POLL_SECONDS}s"
    /usr/local/bin/uvdesk-mailbox-poll.sh &
else
    log "mailbox polling disabled"
fi

apache2ctl configtest
log "starting apache on port $PORT"
exec "$@"
