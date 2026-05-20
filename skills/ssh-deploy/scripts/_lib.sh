#!/usr/bin/env bash
# ssh-deploy/_lib.sh — shim that loads the plugin's shared library and
# defines the parse_args() this skill expects. Sourced by every action
# script (check-target, preflight, init, update-cms, update-theme).
# Not meant to be executed directly.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../shared/ssh-lib.sh
source "${LIB_DIR}/../../../shared/ssh-lib.sh"

# ssh-deploy accepts only --config. Other action-specific flags (target
# path, action verb) come from positional args handled inside each
# script, not from this parser.
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
