#!/usr/bin/env bash
# Backup remote DB tables before any content write.
#
# Streams `mysqldump` output from the remote DB back to a local file at
# /tmp/plooma-content-backup-<ts>.sql. Default tables: items,pages — those are
# the only ones content commands ever touch. Override with --tables for a
# fuller backup if needed.
#
# Why dump just two tables and not the whole DB: speed and clarity. The
# rollback story is "restore items and pages" — full DB dumps include user
# data, form submissions, etc. that have nothing to do with content edits
# and just bloat the file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Defaults overridden by parse_args.
TABLES="items,pages"

parse_args "$@"
require_config

eval "$(resolve_ssh_cmd)"

DB_HOST=$(cfg_get '.db.host')
DB_NAME=$(cfg_get '.db.name')
DB_USER=$(cfg_get '.db.user')
DB_PASS=$(cfg_get '.db.password')

if [[ -z "$DB_NAME" || -z "$DB_USER" ]]; then
    echo "ERROR: db.name / db.user missing in config" >&2
    exit 2
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="/tmp/plooma-content-backup-${TS}.sql"

# Convert comma-separated tables to space-separated for mysqldump.
TABLES_LIST=$(echo "$TABLES" | tr ',' ' ')

log_step "Backing up remote tables [${TABLES}] from ${DB_NAME}@${DB_HOST}"

# --single-transaction: consistent dump without LOCK TABLES (denied by many
#   shared hosts).
# --no-tablespaces: same — works around hostinger/cPanel restrictions.
# Quote each input that interpolates user data so weird passwords/db names
# don't break the remote shell. The dump stdout streams over SSH straight
# to the local file.
remote_dump_cmd="mysqldump --single-transaction --no-tablespaces -u'${DB_USER}' -p'${DB_PASS}' -h'${DB_HOST}' '${DB_NAME}' ${TABLES_LIST}"

if ! eval "$SSH_CMD" "$SSH_TARGET" "$remote_dump_cmd" > "$BACKUP_FILE" 2>/tmp/content-backup-err.log; then
    log_err "Remote mysqldump failed:"
    cat /tmp/content-backup-err.log >&2
    rm -f /tmp/content-backup-err.log "$BACKUP_FILE"
    cat <<EOF
{"ok": false, "error": "mysqldump failed on remote — check credentials or table names. Tables requested: ${TABLES}"}
EOF
    exit 1
fi
rm -f /tmp/content-backup-err.log

SIZE=$(wc -c < "$BACKUP_FILE" | tr -d ' ')
log_ok "Backup written ($SIZE bytes)"

# Single-line JSON so the caller can parse without ceremony.
jq -n \
    --arg path "$BACKUP_FILE" \
    --arg tables "$TABLES" \
    --arg db "$DB_NAME" \
    --arg ssh_target "$SSH_TARGET" \
    --argjson size "$SIZE" \
    --arg ts "$TS" \
    '{
        ok: true,
        backup_path: $path,
        size_bytes: $size,
        tables: ($tables | split(",")),
        database: $db,
        ssh_target: $ssh_target,
        timestamp: $ts,
        rollback_hint: ("mysql -u<user> -p<pass> -h<host> " + $db + " < " + $path)
    }'
