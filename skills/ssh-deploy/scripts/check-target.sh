#!/usr/bin/env bash
# Inspect the remote target for an existing Ellev install.
# Prints "EXISTS" or "EMPTY" to stdout (consumable). Logs progress to stderr.
# Exits 0 on either result, non-zero only on SSH/auth failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

parse_args "$@"

build_ssh_args
remote_path=$(remote_base_path)

step "Inspecting ${ssh_target}:${remote_path}"

# Test SSH connectivity first (with BatchMode in build_ssh_args).
if ! "${ssh_args[@]}" -o ConnectTimeout=10 "echo OK" >/dev/null 2>&1; then
    err "SSH connection failed. Check key auth (ssh-copy-id), host alias in ~/.ssh/config, or ssh.* fields in config."
    exit 2
fi
ok "SSH OK"

# Check for the canonical Ellev marker file.
result=$("${ssh_args[@]}" "test -f '${remote_path}/core/Bootstrap.php' && echo EXISTS || echo EMPTY" 2>/dev/null || echo "ERROR")

case "$result" in
    EXISTS)
        ok "Ellev detected at ${remote_path}"
        echo "EXISTS"
        ;;
    EMPTY)
        ok "Target is empty (no Ellev install)"
        echo "EMPTY"
        ;;
    *)
        err "Could not inspect target. Remote returned: $result"
        exit 3
        ;;
esac
