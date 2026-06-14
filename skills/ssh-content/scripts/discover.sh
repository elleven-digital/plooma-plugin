#!/usr/bin/env bash
# Discover what content lives on a Plooma site, in one round-trip.
#
# Outputs a single JSON document on stdout with the SSH target, remote path,
# all item types defined in site.json, and all configured pages. The skill
# uses this as ground truth before composing any operation — no assumptions
# about what types/pages exist on a given site.
#
# This is a READ-ONLY operation. Doesn't write anything anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

parse_args "$@"
require_config

eval "$(resolve_ssh_cmd)"
REMOTE_PATH=$(cfg_get '.ssh.remote_path')

# Two SSH calls — one for item types, one for pages. We could merge them in
# a single SSH call with `&&`, but parsing two separate JSON outputs is
# cleaner than building a combined wrapper command.

log_step "Discovering content on ${SSH_TARGET}:${REMOTE_PATH}"

types_json=$(remote_plooma "item:types --format=json" 2>/tmp/discover-err.log) || {
    log_err "Failed to call bin/plooma item:types on remote."
    cat /tmp/discover-err.log >&2
    rm -f /tmp/discover-err.log
    cat <<EOF
{"ok": false, "error": "Could not run 'bin/plooma item:types' on remote. The server may have an older Plooma without content commands. Upgrade required: commit dcebc50 or later.", "ssh_target": "${SSH_TARGET}"}
EOF
    exit 1
}

pages_json=$(remote_plooma "page:list --format=json" 2>/tmp/discover-err.log) || {
    log_err "Failed to call bin/plooma page:list on remote."
    cat /tmp/discover-err.log >&2
    rm -f /tmp/discover-err.log
    cat <<EOF
{"ok": false, "error": "Could not run 'bin/plooma page:list' on remote.", "ssh_target": "${SSH_TARGET}"}
EOF
    exit 1
}
rm -f /tmp/discover-err.log

# Sanity: both responses should parse as JSON with ok=true.
if ! echo "$types_json" | jq -e '.ok == true' >/dev/null 2>&1; then
    log_err "Remote item:types returned a non-success response."
    echo "$types_json" >&2
    exit 1
fi
if ! echo "$pages_json" | jq -e '.ok == true' >/dev/null 2>&1; then
    log_err "Remote page:list returned a non-success response."
    echo "$pages_json" >&2
    exit 1
fi

log_ok "$(echo "$types_json" | jq '.types | length') item types, $(echo "$pages_json" | jq '.pages | length') pages"

# Combine into a single envelope. Add ssh_target and remote_path so the
# skill has all the context it needs in one place.
jq -n \
    --arg ssh_target "$SSH_TARGET" \
    --arg remote_path "$REMOTE_PATH" \
    --argjson types "$(echo "$types_json" | jq '.types')" \
    --argjson pages "$(echo "$pages_json" | jq '.pages')" \
    '{
        ok: true,
        ssh_target: $ssh_target,
        remote_path: $remote_path,
        item_types: $types,
        pages: $pages
    }'
