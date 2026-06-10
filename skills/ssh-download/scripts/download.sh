#!/usr/bin/env bash
# Main download operation for ellev:ssh-download.
#
# Modes:
#   --mode A  → first-time download into an empty (or near-empty) folder
#   --mode B  → refresh an existing Ellev install: BACKUP + WIPE + replace
#
# Both modes end with a working local Ellev that mirrors the remote, with
# .env adjusted for local development.
#
# Usage: download.sh --config <path> --mode <A|B> [--backup <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Defaults; overridden by parse_args
MODE=""
BACKUP_DIR=""

parse_args "$@"
require_config

if [[ "$MODE" != "A" && "$MODE" != "B" ]]; then
    echo "ERROR: --mode must be A or B (got '${MODE}')" >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Load config into shell vars (so we don't lose it when wiping the folder)
# ─────────────────────────────────────────────────────────────────────────────
log_step "Loading config"

# Resolve the config path to absolute BEFORE we potentially wipe the folder —
# otherwise relative paths would dangle after the wipe.
CONFIG_PATH=$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH")

# Snapshot the entire config file content; we'll need to rewrite it after wipe.
CONFIG_CONTENT=$(cat "$CONFIG_PATH")

# Extract everything we need.
eval "$(resolve_ssh_cmd)"

REMOTE_PATH=$(cfg_get '.ssh.remote_path')
SITE_LOCAL_URL=$(cfg_get '.site.local_url')
SITE_LOCAL_SUBPATH=$(cfg_get '.site.local_subpath')
REMOTE_DB_HOST=$(cfg_get '.db.host')
REMOTE_DB_NAME=$(cfg_get '.db.name')
REMOTE_DB_USER=$(cfg_get '.db.user')
REMOTE_DB_PASS=$(cfg_get '.db.password')
LOCAL_DB_HOST=$(cfg_get '.local.db_host')
LOCAL_DB_NAME=$(cfg_get '.local.db_name')
LOCAL_DB_USER=$(cfg_get '.local.db_user')
LOCAL_DB_PASS=$(cfg_get '.local.db_password')

# Reusable mysql arg arrays (handle blank password without prompting).
local_mysql_args=(-u"${LOCAL_DB_USER}" -h"${LOCAL_DB_HOST}")
[[ -n "$LOCAL_DB_PASS" ]] && local_mysql_args+=(-p"${LOCAL_DB_PASS}")

CWD=$(pwd)
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_DIR:-/tmp/ellev-download-backup-${TS}}"
REMOTE_DUMP="/tmp/ellev-remote-dump-${TS}.sql"

log_ok "Config loaded — remote: ${SSH_TARGET}:${REMOTE_PATH}"
log_ok "Local target: ${CWD} → DB ${LOCAL_DB_NAME}@${LOCAL_DB_HOST}"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Backup (Mode B only)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "B" ]]; then
    log_step "Backing up current state to ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}/files"

    # Move all visible + hidden entries except . .. and .deploy/ (we keep
    # the live config in memory; backing it up too is fine, but moving the
    # parent .deploy dir would race with later steps if anything reads it).
    # Use shopt to enable dotglob inside a subshell so we don't pollute the
    # caller's shell options.
    (
        shopt -s dotglob nullglob
        for entry in "${CWD}"/*; do
            base=$(basename "$entry")
            # Skip these; we already have the config in memory.
            if [[ "$base" == "." || "$base" == ".." ]]; then
                continue
            fi
            mv "$entry" "${BACKUP_DIR}/files/"
        done
    )

    log_ok "Files moved to ${BACKUP_DIR}/files/"

    log_step "Dumping local DB to ${BACKUP_DIR}/local-db.sql"
    if ! mysqldump "${local_mysql_args[@]}" \
            --single-transaction --no-tablespaces \
            "${LOCAL_DB_NAME}" > "${BACKUP_DIR}/local-db.sql" 2>/tmp/dl-dump.err; then
        log_warn "Local DB dump failed (DB may not exist yet — ok if first run):"
        cat /tmp/dl-dump.err >&2
        rm -f "${BACKUP_DIR}/local-db.sql"  # don't leave a half-written file
    else
        log_ok "Local DB dumped ($(wc -c < "${BACKUP_DIR}/local-db.sql" | tr -d ' ') bytes)"
    fi
    rm -f /tmp/dl-dump.err

    # ─────────────────────────────────────────────────────────────────────────
    # Phase 2: Wipe local DB (Mode B only)
    # ─────────────────────────────────────────────────────────────────────────
    log_step "Dropping and recreating local DB ${LOCAL_DB_NAME}"
    if ! mysql "${local_mysql_args[@]}" -e \
            "DROP DATABASE IF EXISTS \`${LOCAL_DB_NAME}\`; CREATE DATABASE \`${LOCAL_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/tmp/dl-drop.err; then
        log_err "Failed to drop/recreate local DB:"
        cat /tmp/dl-drop.err >&2
        rm -f /tmp/dl-drop.err
        echo "  Backup is at ${BACKUP_DIR} — you can restore manually." >&2
        exit 1
    fi
    rm -f /tmp/dl-drop.err
    log_ok "Local DB recreated empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 (Mode A only): ensure local DB exists
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "A" ]]; then
    log_step "Ensuring local DB ${LOCAL_DB_NAME} exists"
    if ! mysql "${local_mysql_args[@]}" -e \
            "CREATE DATABASE IF NOT EXISTS \`${LOCAL_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/tmp/dl-create.err; then
        log_err "Failed to create local DB:"
        cat /tmp/dl-create.err >&2
        rm -f /tmp/dl-create.err
        exit 1
    fi
    rm -f /tmp/dl-create.err
    log_ok "Local DB ready"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Pull files from remote via rsync
# ─────────────────────────────────────────────────────────────────────────────
log_step "Downloading files from ${SSH_TARGET}:${REMOTE_PATH}/"
# --delete makes local an exact mirror of remote (Mode A: no-op since folder
#   was empty; Mode B: extra safety in case wipe missed anything).
# -a preserves perms/timestamps; -z compresses on the wire.
# Trailing slash on source means "contents of", not "the folder itself".
if ! rsync -avz --delete --human-readable \
        -e "$SSH_CMD" \
        "${SSH_TARGET}:${REMOTE_PATH}/" "${CWD}/" 2>&1 | tail -20; then
    log_err "rsync failed."
    [[ "$MODE" == "B" ]] && echo "  Backup at ${BACKUP_DIR}" >&2
    exit 1
fi
log_ok "Files synced"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: Dump remote DB and import locally
# ─────────────────────────────────────────────────────────────────────────────
log_step "Dumping remote DB ${REMOTE_DB_NAME}"
# --single-transaction: consistent dump without LOCK TABLES (which shared hosts
#   often deny). --no-tablespaces: works around the same restriction.
remote_dump_cmd="mysqldump --single-transaction --no-tablespaces -u'${REMOTE_DB_USER}' -p'${REMOTE_DB_PASS}' -h'${REMOTE_DB_HOST}' '${REMOTE_DB_NAME}'"
if ! eval "$SSH_CMD" "$SSH_TARGET" "$remote_dump_cmd" > "$REMOTE_DUMP" 2>/tmp/dl-rdump.err; then
    log_err "Remote mysqldump failed:"
    cat /tmp/dl-rdump.err >&2
    rm -f /tmp/dl-rdump.err "$REMOTE_DUMP"
    [[ "$MODE" == "B" ]] && echo "  Backup at ${BACKUP_DIR}" >&2
    exit 1
fi
rm -f /tmp/dl-rdump.err
DUMP_SIZE=$(wc -c < "$REMOTE_DUMP" | tr -d ' ')
log_ok "Remote dump received (${DUMP_SIZE} bytes)"

log_step "Importing dump into local DB ${LOCAL_DB_NAME}"
if ! mysql "${local_mysql_args[@]}" "${LOCAL_DB_NAME}" < "$REMOTE_DUMP" 2>/tmp/dl-imp.err; then
    log_err "Local import failed:"
    cat /tmp/dl-imp.err >&2
    rm -f /tmp/dl-imp.err
    echo "  Dump preserved at ${REMOTE_DUMP} for manual investigation." >&2
    [[ "$MODE" == "B" ]] && echo "  Backup at ${BACKUP_DIR}" >&2
    exit 1
fi
rm -f /tmp/dl-imp.err "$REMOTE_DUMP"
log_ok "DB imported"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: Generate local .env
# ─────────────────────────────────────────────────────────────────────────────
log_step "Writing local .env"

# APP_BASE_PATH: empty if subpath is "/" or empty; otherwise the subpath.
APP_BASE_PATH=""
if [[ -n "$SITE_LOCAL_SUBPATH" && "$SITE_LOCAL_SUBPATH" != "/" ]]; then
    APP_BASE_PATH="$SITE_LOCAL_SUBPATH"
fi

# Decide how to mark APP_ENV. Local, by definition.
cat > "${CWD}/.env" <<EOF
APP_ENV=local
APP_DEBUG=true
APP_URL=${SITE_LOCAL_URL}
APP_BASE_PATH=${APP_BASE_PATH}

DB_CONNECTION=mysql
DB_HOST=${LOCAL_DB_HOST}
DB_PORT=3306
DB_DATABASE=${LOCAL_DB_NAME}
DB_USERNAME=${LOCAL_DB_USER}
DB_PASSWORD=${LOCAL_DB_PASS}

# SMTP intentionally blank for local dev (no accidental sends).
SMTP_HOST=
SMTP_PORT=
SMTP_USER=
SMTP_PASS=
SMTP_FROM=
SMTP_FROM_NAME=

# INITIAL_USER blank — admin already exists in imported DB.
INITIAL_USER_NAME=
INITIAL_USER_EMAIL=
INITIAL_USER_PASSWORD=
EOF
chmod 0600 "${CWD}/.env"
log_ok ".env written (chmod 0600)"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: Permissions for storage/ (so local web server can write)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -d "${CWD}/storage" ]]; then
    log_step "Setting storage/ permissions to 0775"
    chmod -R 0775 "${CWD}/storage" 2>/dev/null || \
        log_warn "Could not chmod storage/ (non-fatal — fix manually if local server can't write)"
    log_ok "storage/ writable"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8: Restore .deploy/ssh.json (Mode B wiped it; Mode A wrote it earlier)
# ─────────────────────────────────────────────────────────────────────────────
log_step "Restoring .deploy/ssh.json"
mkdir -p "${CWD}/.deploy"
echo "$CONFIG_CONTENT" > "${CWD}/.deploy/ssh.json"
chmod 0600 "${CWD}/.deploy/ssh.json"
log_ok ".deploy/ssh.json saved"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo
log_ok "Download complete."
echo
echo "  Local path:   ${CWD}"
echo "  Local DB:     ${LOCAL_DB_NAME} @ ${LOCAL_DB_HOST}"
echo "  Local URL:    ${SITE_LOCAL_URL}"
if [[ "$MODE" == "B" ]]; then
    echo "  Backup:       ${BACKUP_DIR}"
    echo "                  (delete after you verify the new state works)"
fi
echo
echo "  Test it:"
echo "    ./bin/nano serve 8080"
echo "    # or use your local web server (Apache/Nginx) pointed at this folder"
echo
echo "  Login at ${SITE_LOCAL_URL}/admin/login with your production credentials."
exit 0
