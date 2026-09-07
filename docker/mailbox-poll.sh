#!/bin/bash
# Turns incoming email into tickets on the schedule upstream documents as a
# cron entry. Runs inside the web container because Railway volumes are 1:1 and
# the mailbox configuration this reads is written by the admin UI onto that
# volume. Silent and harmless until a mailbox is configured.
set -uo pipefail

HOME_DIR="${UVDESK_HOME:-/var/www/uvdesk}"
INTERVAL="${UVDESK_MAILBOX_POLL_SECONDS:-300}"
RUN_USER="www-data"

log() { printf '[uvdesk-mailbox] %s\n' "$*"; }

# Give Apache time to come up before the first pass.
sleep 30

while true; do
    mapfile -t MAILBOXES < <(php /opt/uvdesk-railway/bin/mailbox-emails.php 2>/dev/null)

    if [ "${#MAILBOXES[@]}" -gt 0 ]; then
        log "refreshing ${#MAILBOXES[@]} mailbox(es)"
        setpriv --reuid="$(id -u "$RUN_USER")" --regid="$(id -g "$RUN_USER")" --init-groups \
            env HOME=/tmp php "$HOME_DIR/bin/console" uvdesk:refresh-mailbox \
            "${MAILBOXES[@]}" --no-interaction 2>&1 | sed 's/^/[uvdesk-mailbox] /'
    fi

    sleep "$INTERVAL"
done
