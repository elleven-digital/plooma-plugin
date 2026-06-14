#!/usr/bin/env bash
# shared/ssh-lib.sh — helpers compartilhados pelas três skills ssh-*
# (ssh-deploy, ssh-download, ssh-content).
#
# Sourced indirectly via each skill's scripts/_lib.sh shim. The shim
# resolves the relative path up to the plugin root:
#
#   LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${LIB_DIR}/../../../shared/ssh-lib.sh"
#
# Don't source this file directly from action scripts — go through the
# local _lib.sh so `parse_args` (which is skill-specific) gets defined.
#
# Two SSH APIs coexist on purpose:
#
#   1. Array-style (ssh-deploy historical) — build_ssh_args sets the
#      `ssh_args` array + `ssh_target` string; callers do
#      `"${ssh_args[@]}" "remote command"`.
#
#   2. Eval-style (ssh-download, ssh-content) — resolve_ssh_cmd echoes
#      a snippet you `eval` to set SSH_CMD + SSH_TARGET; callers do
#      `$SSH_CMD "$SSH_TARGET" "remote command"`.
#
# Both should produce the same observable behavior. They look different
# because the skills were written at different times. Unifying them
# would require rewriting every action script — not worth it just to
# pick one style. Keep both, document the choice, move on.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Pretty output
# ─────────────────────────────────────────────────────────────────────
# Two naming styles for historical reasons:
#   - short names (step/ok/warn/err/dim) used by ssh-deploy
#   - log_* names used by ssh-download and ssh-content
# Both write to stderr so stdout stays clean for data payloads.

C_BLUE='\033[0;34m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_DIM='\033[2m'
C_RESET='\033[0m'

step()  { echo -e "${C_BLUE}▸${C_RESET} $*" >&2; }
ok()    { echo -e "${C_GREEN}✓${C_RESET} $*" >&2; }
warn()  { echo -e "${C_YELLOW}!${C_RESET} $*" >&2; }
err()   { echo -e "${C_RED}✗${C_RESET} $*" >&2; }
dim()   { echo -e "${C_DIM}$*${C_RESET}" >&2; }

# Different glyph/spacing convention used by the newer skills.
log_step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*" >&2; }
log_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*" >&2; }
log_warn() { printf '  \033[1;33m⚠\033[0m %s\n' "$*" >&2; }
log_err()  { printf '  \033[1;31m✗ ERROR:\033[0m %s\n' "$*" >&2; }

die() {
    err "$*"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────
# Config access
# ─────────────────────────────────────────────────────────────────────

# cfg_get '.dot.path' [default]
# Returns the JSON value at path, or default (or empty) if absent/null.
# The `[default]` arg is optional — older call sites in ssh-download
# and ssh-content pass only the path.
cfg_get() {
    local path="$1"
    local default="${2:-}"
    local val
    val=$(jq -r "${path} // empty" "$CONFIG_PATH" 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Validates that CONFIG_PATH is set and points to a parseable JSON file.
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

# ─────────────────────────────────────────────────────────────────────
# SSH — array-style API (ssh-deploy)
# ─────────────────────────────────────────────────────────────────────
# Sets globals: ssh_args (array), ssh_target (string for display).
# Usage:
#   build_ssh_args
#   "${ssh_args[@]}" "remote command"
build_ssh_args() {
    local alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then
        ssh_args=("ssh" "$alias")
        ssh_target="$alias"
        return
    fi
    local host port user key
    host=$(cfg_get '.ssh.host')
    port=$(cfg_get '.ssh.port' '22')
    user=$(cfg_get '.ssh.user')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    [[ -z "$host" || -z "$user" ]] && die "ssh config must provide either alias OR host+user (+ optional port/key_path)"
    key="${key/#\~/$HOME}"
    ssh_args=("ssh" "-p" "$port" "-i" "$key" "-o" "BatchMode=yes" "${user}@${host}")
    ssh_target="${user}@${host}"
}

# rsync remote shell prefix matching build_ssh_args.
# Usage: rsh=$(rsync_remote_shell); rsync -e "$rsh" ...
rsync_remote_shell() {
    local alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then
        echo "ssh"
        return
    fi
    local port key
    port=$(cfg_get '.ssh.port' '22')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    key="${key/#\~/$HOME}"
    echo "ssh -p $port -i $key -o BatchMode=yes"
}

# Returns "user@host:path" or "alias:path" for rsync/scp.
rsync_target_for() {
    local remote="$1"
    local alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then
        echo "${alias}:${remote}"
        return
    fi
    local host user
    host=$(cfg_get '.ssh.host')
    user=$(cfg_get '.ssh.user')
    echo "${user}@${host}:${remote}"
}

# ─────────────────────────────────────────────────────────────────────
# SSH — eval-style API (ssh-download, ssh-content)
# ─────────────────────────────────────────────────────────────────────
# Echoes a shell snippet that sets SSH_CMD and SSH_TARGET when eval'd.
# Usage:
#   eval "$(resolve_ssh_cmd)"
#   $SSH_CMD "$SSH_TARGET" "remote command"
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

# ─────────────────────────────────────────────────────────────────────
# Remote path
# ─────────────────────────────────────────────────────────────────────
# Required field on most hosts — varies wildly:
#   Hostinger shared:   /home/uXXX/domains/<domain>/public_html
#   cPanel shared:      /home/<user>/public_html
#   Locaweb/KingHost:   /home/<user>/www  or similar
#   DreamHost:          /home/<user>/<domain>
#   VPS/cloud:          anywhere — typically /var/www/<project> or /srv/<domain>
remote_path() {
    local path
    path=$(cfg_get '.ssh.remote_path')
    if [[ -z "$path" ]]; then
        die "ssh.remote_path is required in config — absolute path on the remote host where Plooma lives (e.g. /var/www/site, /home/user/public_html, /home/u123/domains/site.com/public_html)"
    fi
    # Strip trailing slash for consistent concatenation.
    echo "${path%/}"
}

# Older alias kept around for backward compat with any caller still using it.
remote_base_path() {
    remote_path
}

# ─────────────────────────────────────────────────────────────────────
# Database
# ─────────────────────────────────────────────────────────────────────
# Remote credentials live under .db; local under .local.db_*.
# Used primarily by ssh-deploy (push DB to remote) and ssh-download
# (dump remote, restore local).

remote_db_args() {
    local host name user pass
    host=$(cfg_get '.db.host' 'localhost')
    name=$(cfg_get '.db.name')
    user=$(cfg_get '.db.user')
    pass=$(cfg_get '.db.password')
    [[ -z "$name" || -z "$user" || -z "$pass" ]] && die "db.{name,user,password} must be set in config"
    echo "-h$host -u$user -p$pass $name"
}

local_db_dump_cmd() {
    local host name user pass
    host=$(cfg_get '.local.db_host' 'localhost')
    name=$(cfg_get '.local.db_name')
    user=$(cfg_get '.local.db_user' 'root')
    pass=$(cfg_get '.local.db_password' '')
    [[ -z "$name" ]] && die "local.db_name must be set in config"
    if [[ -z "$pass" ]]; then
        echo "mysqldump -h$host -u$user --no-tablespaces $name"
    else
        echo "mysqldump -h$host -u$user -p$pass --no-tablespaces $name"
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Interactive prompts (ssh-download)
# ─────────────────────────────────────────────────────────────────────
confirm_yes() {
    local prompt="${1:-Continue?}"
    local reply
    read -r -p "$prompt (y/N) " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Requires the user to type an exact phrase (e.g. "REFRESH") to proceed.
# Used for destructive operations where (y/N) is too easy to fat-finger.
confirm_phrase() {
    local expected="$1"
    local prompt="${2:-Type the confirmation phrase}"
    local reply
    read -r -p "$prompt: " reply
    [[ "$reply" == "$expected" ]]
}

# ─────────────────────────────────────────────────────────────────────
# bin/plooma on the remote (ssh-content)
# ─────────────────────────────────────────────────────────────────────
# Lets sites override which PHP interpreter runs — useful on shared
# hosts where multiple PHP versions live side-by-side and the default
# `php` in PATH isn't the one Plooma expects.
resolve_php_bin() {
    local p
    p=$(cfg_get '.remote.php_bin')
    echo "${p:-php}"
}

# cd into the remote project + set PHP_BIN. Caller appends the bin/plooma
# subcommand. Matches the way the user runs commands themselves on the
# server (no absolute paths, no surprises).
remote_prefix() {
    local rp php_bin
    rp=$(cfg_get '.ssh.remote_path')
    php_bin=$(resolve_php_bin)
    if [[ -z "$rp" ]]; then
        echo "ERROR: ssh.remote_path missing in config" >&2
        exit 2
    fi
    echo "cd ${rp} && PHP_BIN='${php_bin}' "
}

# Runs a bin/plooma subcommand on the remote. Returns its stdout (JSON
# when --format=json was passed).
# Usage: remote_plooma "item:list posts --format=json --status=draft"
remote_plooma() {
    local subcommand="$1"
    local prefix
    prefix=$(remote_prefix)
    eval "$SSH_CMD" "$SSH_TARGET" "${prefix}./bin/plooma ${subcommand}"
}

# Same as remote_plooma but pipes the caller's stdin to the remote
# command — used for --json-stdin payloads where shell-escaping a JSON
# literal would be painful.
remote_plooma_stdin() {
    local subcommand="$1"
    local prefix
    prefix=$(remote_prefix)
    eval "$SSH_CMD" "$SSH_TARGET" "${prefix}./bin/plooma ${subcommand}"
}
