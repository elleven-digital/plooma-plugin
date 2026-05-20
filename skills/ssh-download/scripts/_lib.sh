#!/usr/bin/env bash
# Shared helpers for nano-cms:ssh-download scripts.
# Source this from the actual scripts, don't run it directly.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Config loading
# ─────────────────────────────────────────────────────────────────────────────
# Reads a single dot-path value from the JSON config.
# Usage: cfg_get '.ssh.alias'  → echoes the value, or empty string if null/absent
cfg_get() {
    local path="$1"
    jq -r "${path} // empty" "$CONFIG_PATH" 2>/dev/null
}

# Validates that the config file exists and is parseable JSON.
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
# SSH command resolution
# ─────────────────────────────────────────────────────────────────────────────
# Builds the SSH command-line based on config. Two modes:
#   1. ssh.alias is set → use it as the only argument
#   2. ssh.host + port + user + key → build explicit command
# Echoes the SSH command (without trailing args, so caller appends what to do).
# Usage:
#   eval "$(resolve_ssh_cmd)"   # sets SSH_CMD and SSH_TARGET shell vars
#
# After this, you can do: $SSH_CMD "$SSH_TARGET" "remote command"
# Or for rsync: rsync ... -e "$SSH_CMD" "$SSH_TARGET:path" ...
resolve_ssh_cmd() {
    local alias host port user key

    alias=$(cfg_get '.ssh.alias')
    host=$(cfg_get '.ssh.host')
    port=$(cfg_get '.ssh.port')
    user=$(cfg_get '.ssh.user')
    key=$(cfg_get '.ssh.key_path')

    if [[ -n "$alias" ]]; then
        # Use the alias as-is. ssh resolves everything from ~/.ssh/config.
        echo "SSH_CMD='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new'"
        echo "SSH_TARGET='${alias}'"
    else
        if [[ -z "$host" || -z "$user" ]]; then
            echo "echo 'ERROR: ssh config missing — provide either ssh.alias OR ssh.host+ssh.user.' >&2"
            echo "exit 2"
            return
        fi
        # Resolve key path (expand ~)
        local key_resolved
        key_resolved=$(eval echo "${key:-~/.ssh/id_ed25519}")
        local port_arg=""
        [[ -n "$port" && "$port" != "22" ]] && port_arg="-p ${port}"
        echo "SSH_CMD='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i ${key_resolved} ${port_arg}'"
        echo "SSH_TARGET='${user}@${host}'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# User interaction
# ─────────────────────────────────────────────────────────────────────────────
# Yes/No prompt. Returns 0 if user says yes, 1 otherwise.
# Usage: confirm_yes "Continue?" || exit 0
confirm_yes() {
    local prompt="${1:-Continue?}"
    local reply
    read -r -p "$prompt (y/N) " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Strict typed confirmation. Returns 0 only if user types the exact phrase.
# Usage: confirm_phrase "REFRESH" "Type REFRESH to continue:" || exit 0
confirm_phrase() {
    local expected="$1"
    local prompt="${2:-Type the confirmation phrase}"
    local reply
    read -r -p "$prompt: " reply
    [[ "$reply" == "$expected" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
log_step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*" >&2; }
log_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*" >&2; }
log_warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
log_err()  { printf '  \033[1;31m✗ ERROR:\033[0m %s\n' "$*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
# Parses --config <path> (and other --key value flags).
# Usage at top of caller:
#   source "$(dirname "$0")/_lib.sh"
#   parse_args "$@"
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) CONFIG_PATH="$2"; shift 2 ;;
            --mode)   MODE="$2";        shift 2 ;;
            --backup) BACKUP_DIR="$2";  shift 2 ;;
            --help|-h)
                echo "Usage: $0 --config <path-to-ssh.json> [--mode A|B] [--backup <dir>]" >&2
                exit 0
                ;;
            *) echo "Unknown arg: $1" >&2; exit 2 ;;
        esac
    done
}
