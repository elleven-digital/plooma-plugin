#!/usr/bin/env bash
# ssh-download/_lib.sh — shim that loads the plugin's shared library
# and defines the parse_args() this skill expects.
# Source it from action scripts; don't run it directly.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../shared/ssh-lib.sh
source "${LIB_DIR}/../../../shared/ssh-lib.sh"

# Flags recognized by ssh-download action scripts:
#   --config <path>   .deploy/ssh.json (required)
#   --mode A|B        first-time vs refresh
#   --backup <dir>    where to stash local state before destructive ops
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
