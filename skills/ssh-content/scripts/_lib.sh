#!/usr/bin/env bash
# Shared helpers for nano-cms:ssh-content scripts.
# Source this from the actual scripts, don't run it directly.
#
# Mirrors the patterns in nano-cms:ssh-deploy/_lib.sh and nano-cms:ssh-download/_lib.sh
# so .deploy/ssh.json works seamlessly across all three skills.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Config loading
# ─────────────────────────────────────────────────────────────────────────────

# Reads a single dot-path value from the JSON config.
# Usage: cfg_get '.ssh.alias' → echoes the value, or empty if null/absent
cfg_get() {
    local path="$1"
    jq -r "${path} // empty" "$CONFIG_PATH" 2>/dev/null
}

require_config() {
    if [[ -z "${CONFIG_PATH:-}" ]]; then
        echo "ERROR: CONFIG_PATH not set. Pass --config <path>." >&2
        exit 2
    fi
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "ERROR: Config not found at $CONFIG_PATH" >&2
        exit 2
    fi
    if ! jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
        echo "ERROR: Config at $CONFIG_PATH is not valid JSON" >&2
        exit 2
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH command resolution (same logic as the deploy/download skills)
# ─────────────────────────────────────────────────────────────────────────────
# Builds the SSH command-line based on config. Two modes:
#   1. ssh.alias is set → use it as the only argument
#   2. ssh.host + port + user + key → build explicit command
# Echoes a snippet that, when eval'd, sets SSH_CMD and SSH_TARGET vars.
#
# Usage: eval "$(resolve_ssh_cmd)"
# After: $SSH_CMD "$SSH_TARGET" "remote command"
resolve_ssh_cmd() {
    local alias host port user key

    alias=$(cfg_get '.ssh.alias')
    host=$(cfg_get '.ssh.host')
    port=$(cfg_get '.ssh.port')
    user=$(cfg_get '.ssh.user')
    key=$(cfg_get '.ssh.key_path')

    if [[ -n "$alias" ]]; then
        echo "SSH_CMD='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'"
        echo "SSH_TARGET='${alias}'"
    else
        if [[ -z "$host" || -z "$user" ]]; then
            echo "echo 'ERROR: ssh config missing — provide ssh.alias OR ssh.host+ssh.user.' >&2"
            echo "exit 2"
            return
        fi
        local key_resolved
        key_resolved=$(eval echo "${key:-~/.ssh/id_ed25519}")
        local port_arg=""
        [[ -n "$port" && "$port" != "22" ]] && port_arg="-p ${port}"
        echo "SSH_CMD='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i ${key_resolved} ${port_arg}'"
        echo "SSH_TARGET='${user}@${host}'"
    fi
}

# Resolves the optional php binary path. Returns "php" if not configured;
# allows shared hosts where php isn't in PATH to specify a full path.
resolve_php_bin() {
    local p
    p=$(cfg_get '.remote.php_bin')
    echo "${p:-php}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging (stderr — leaves stdout for JSON payloads)
# ─────────────────────────────────────────────────────────────────────────────
log_step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*" >&2; }
log_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*" >&2; }
log_warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
log_err()  { printf '  \033[1;31m✗ ERROR:\033[0m %s\n' "$*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
# Recognized flags:
#   --config <path>     — path to .deploy/ssh.json (required)
#   --action <verb>     — for write.sh: item:create, item:update, page:update, etc.
#   --target <name>     — type (for items) or page key (for pages)
#   --slug <slug>       — slug-or-id (for item updates/get/delete)
#   --tables <list>     — for backup.sh, comma-separated table list
#   --confirm           — explicit confirmation for destructive ops (item:delete)
#   --dry-run           — pass through to bin/nano for validation only
#   --json-stdin        — write.sh reads JSON payload from its OWN stdin
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)     CONFIG_PATH="$2";   shift 2 ;;
            --action)     ACTION="$2";        shift 2 ;;
            --target)     TARGET="$2";        shift 2 ;;
            --slug)       SLUG="$2";          shift 2 ;;
            --tables)     TABLES="$2";        shift 2 ;;
            --confirm)    CONFIRM=1;          shift   ;;
            --dry-run)    DRY_RUN=1;          shift   ;;
            --json-stdin) JSON_STDIN=1;       shift   ;;
            --help|-h)
                cat >&2 <<'EOF'
Usage:
  discover.sh --config <ssh.json>
  backup.sh   --config <ssh.json> [--tables items,pages]
  write.sh    --config <ssh.json> --action <verb> --target <name> [--slug <slug>] [--confirm] [--dry-run] [--json-stdin]
EOF
                exit 0
                ;;
            *) echo "Unknown arg: $1" >&2; exit 2 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Remote command builder
# ─────────────────────────────────────────────────────────────────────────────
# Builds the cd-and-execute prefix. Caller appends the bin/nano subcommand.
# Why `cd && ./bin/nano` instead of an absolute path: matches how the user
# runs commands themselves on the server, no surprises.
remote_prefix() {
    local remote_path php_bin
    remote_path=$(cfg_get '.ssh.remote_path')
    php_bin=$(resolve_php_bin)
    if [[ -z "$remote_path" ]]; then
        echo "ERROR: ssh.remote_path missing in config" >&2
        exit 2
    fi
    # PHP_BIN env var lets sites override which php interpreter runs, useful
    # for hosts where multiple PHP versions live side-by-side.
    echo "cd ${remote_path} && PHP_BIN='${php_bin}' "
}

# Runs a bin/nano command on the remote. Returns the stdout (which is JSON
# when --format=json was passed). Stderr from the remote bubbles up.
# Usage:
#   remote_nano "item:list posts --format=json --status=draft"
remote_nano() {
    local subcommand="$1"
    local prefix
    prefix=$(remote_prefix)
    eval "$SSH_CMD" "$SSH_TARGET" "${prefix}./bin/nano ${subcommand}"
}

# Runs a bin/nano command on the remote, piping local stdin to remote stdin.
# Used for --json-stdin payloads where shell-escaping a JSON literal is
# painful.
remote_nano_stdin() {
    local subcommand="$1"
    local prefix
    prefix=$(remote_prefix)
    eval "$SSH_CMD" "$SSH_TARGET" "${prefix}./bin/nano ${subcommand}"
}
