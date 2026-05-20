#!/usr/bin/env bash
# Shared helpers for nano-deploy-hostinger scripts.
# Sourced by each action script (check-target, preflight, init, update-cms, update-theme).
# Not meant to be executed directly.

set -euo pipefail

# ---- pretty output ----

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

die() {
    err "$*"
    exit 1
}

# ---- arg parsing ----

CONFIG_PATH=""
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) CONFIG_PATH="$2"; shift 2 ;;
            *) die "Unknown arg: $1" ;;
        esac
    done
    [[ -z "$CONFIG_PATH" ]] && die "Usage: $0 --config <path-to-ssh.json>"
    [[ ! -f "$CONFIG_PATH" ]] && die "Config not found: $CONFIG_PATH"
    command -v jq >/dev/null || die "jq is required (brew install jq / apt install jq)"
}

# ---- config access ----

cfg_get() {
    # cfg_get '.path.to.field' [default]
    local path="$1"
    local default="${2:-}"
    local val
    val=$(jq -r "$path // empty" "$CONFIG_PATH")
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# ---- SSH ----

# Builds the ssh command prefix as a bash array, supporting either
# the alias form (~/.ssh/config) or direct host/port/user/key.
# Usage: ssh_args=(); build_ssh_args; "${ssh_args[@]}" -- echo hi
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
    # Expand ~
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
        # Use alias by passing it as the host directly to rsync — rsync uses ssh which honors ~/.ssh/config
        echo "ssh"
        return
    fi
    local port key
    port=$(cfg_get '.ssh.port' '22')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    key="${key/#\~/$HOME}"
    echo "ssh -p $port -i $key -o BatchMode=yes"
}

# Returns the user@host:path or alias:path target for rsync/scp.
rsync_target_for() {
    # rsync_target_for "<remote-path>"
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

# ---- remote path ----

# Returns the absolute path on the remote host where Nano lives.
# Required field: ssh.remote_path. No guessing — the user (or the setup
# wizard in SKILL.md Phase 1) must supply this explicitly because it
# varies wildly by host:
#
#   Hostinger shared:  /home/uXXX/domains/<domain>/public_html
#   cPanel shared:     /home/<user>/public_html
#   Locaweb / KingHost: /home/<user>/www  or similar
#   DreamHost:         /home/<user>/<domain>
#   VPS / cloud VM:    anywhere — typically /var/www/<project> or /srv/<domain>
remote_path() {
    local path
    path=$(cfg_get '.ssh.remote_path')
    if [[ -z "$path" ]]; then
        die "ssh.remote_path is required in config — absolute path on the remote host where Nano lives (e.g. /var/www/site, /home/user/public_html, /home/u123/domains/site.com/public_html)"
    fi
    # Strip trailing slash for consistent concatenation
    echo "${path%/}"
}

# Backwards-compat alias for older script names. Calls remote_path().
remote_base_path() {
    remote_path
}

# ---- DB ----

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
