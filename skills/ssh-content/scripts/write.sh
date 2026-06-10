#!/usr/bin/env bash
# Execute a single content write operation on the remote Ellev site.
#
# Maps a high-level --action (item:create, page:update, etc.) onto the
# matching bin/nano subcommand on the remote, with proper flag plumbing
# (--json-stdin, --dry-run, --confirm, --format=json). Returns the JSON
# response from bin/nano on stdout.
#
# Why this script exists when the model could just SSH directly:
#   - Hides the SSH command/target resolution behind --config (skill stays
#     focused on intent, not transport)
#   - Routes JSON payloads through stdin properly (avoids quoting hell)
#   - Single place for "how do we talk to bin/nano" — easy to evolve
#   - Predictable error envelope ({"ok": false, ...}) when SSH or nano fails
#
# This script DOES NOT perform a backup. The skill is expected to call
# backup.sh BEFORE write.sh for any non-trivial write. Keeping them split
# means batch operations don't have to redump the DB for every single write.
#
# Supported actions:
#   item:create <type>           JSON via stdin
#   item:update <type> <slug>    JSON via stdin
#   item:publish <type> <slug>
#   item:unpublish <type> <slug>
#   item:delete <type> <slug>    (requires --confirm)
#   page:update <key>            JSON via stdin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Defaults (overridden by parse_args).
ACTION=""
TARGET=""
SLUG=""
CONFIRM=0
DRY_RUN=0
JSON_STDIN=0

parse_args "$@"
require_config

if [[ -z "$ACTION" || -z "$TARGET" ]]; then
    cat <<EOF >&2
ERROR: --action and --target are required.

Examples:
  write.sh --config .deploy/ssh.json --action item:create   --target post --json-stdin
  write.sh --config .deploy/ssh.json --action item:update   --target post --slug hello --json-stdin
  write.sh --config .deploy/ssh.json --action item:publish  --target post --slug hello
  write.sh --config .deploy/ssh.json --action item:delete   --target post --slug hello --confirm
  write.sh --config .deploy/ssh.json --action page:update   --target home --json-stdin
EOF
    exit 2
fi

eval "$(resolve_ssh_cmd)"

# ─────────────────────────────────────────────────────────────────────────────
# Build the bin/nano subcommand based on --action
# ─────────────────────────────────────────────────────────────────────────────
NEEDS_JSON=0
NEEDS_SLUG=0
NEEDS_CONFIRM=0
case "$ACTION" in
    item:create)        NANO_VERB="item:create"   ; NEEDS_JSON=1 ;;
    item:update)        NANO_VERB="item:update"   ; NEEDS_JSON=1 ; NEEDS_SLUG=1 ;;
    item:publish)       NANO_VERB="item:publish"  ; NEEDS_SLUG=1 ;;
    item:unpublish)     NANO_VERB="item:unpublish"; NEEDS_SLUG=1 ;;
    item:delete)        NANO_VERB="item:delete"   ; NEEDS_SLUG=1 ; NEEDS_CONFIRM=1 ;;
    page:update)        NANO_VERB="page:update"   ; NEEDS_JSON=1 ;;
    *)
        echo "{\"ok\": false, \"error\": \"Unknown --action '${ACTION}'. Supported: item:create, item:update, item:publish, item:unpublish, item:delete, page:update\"}" >&2
        exit 2
        ;;
esac

if [[ "$NEEDS_SLUG" == "1" && -z "$SLUG" ]]; then
    echo "{\"ok\": false, \"error\": \"Action '${ACTION}' requires --slug.\"}" >&2
    exit 2
fi
if [[ "$NEEDS_CONFIRM" == "1" && "$CONFIRM" != "1" ]]; then
    echo "{\"ok\": false, \"error\": \"Action '${ACTION}' is destructive — pass --confirm to proceed.\"}" >&2
    exit 2
fi
# JSON-stdin check happens here (before log_step) so we don't print
# "Executing on …" only to immediately reject the invocation.
if [[ "$NEEDS_JSON" == "1" && "$JSON_STDIN" != "1" ]]; then
    echo "{\"ok\": false, \"error\": \"Action '${ACTION}' needs JSON — pipe it via stdin and pass --json-stdin.\"}" >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Build the remote command line
# ─────────────────────────────────────────────────────────────────────────────
# We always pass --format=json so callers parse uniformly.
remote_args="${TARGET}"
[[ "$NEEDS_SLUG" == "1" ]] && remote_args="${remote_args} ${SLUG}"
remote_args="${remote_args} --format=json"
[[ "$NEEDS_JSON" == "1" ]] && remote_args="${remote_args} --json-stdin"
[[ "$DRY_RUN" == "1" ]] && remote_args="${remote_args} --dry-run"
[[ "$CONFIRM" == "1" && "$NEEDS_CONFIRM" == "1" ]] && remote_args="${remote_args} --confirm"

REMOTE_PREFIX=$(remote_prefix)
REMOTE_CMD="${REMOTE_PREFIX}./bin/nano ${NANO_VERB} ${remote_args}"

log_step "Executing on ${SSH_TARGET}: bin/nano ${NANO_VERB} ${remote_args}"

# ─────────────────────────────────────────────────────────────────────────────
# Run via SSH. When the action needs JSON, capture local stdin and pipe
# straight into the SSH stdin → remote bin/nano stdin (which has --json-stdin).
# ─────────────────────────────────────────────────────────────────────────────
# Runs the SSH call. With JSON_STDIN=1, local stdin (which is the user's
# piped-in JSON) flows through SSH to the remote bin/nano process — that's
# the default ssh behavior and we don't have to do anything special.
if ! eval "$SSH_CMD" "$SSH_TARGET" "$REMOTE_CMD" 2>/tmp/write-err.log; then
    log_err "Remote command failed:"
    cat /tmp/write-err.log >&2
    rm -f /tmp/write-err.log
    echo "{\"ok\": false, \"error\": \"SSH or remote bin/nano failed — see stderr.\"}"
    exit 1
fi
rm -f /tmp/write-err.log
