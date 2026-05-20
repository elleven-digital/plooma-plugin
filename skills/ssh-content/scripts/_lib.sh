#!/usr/bin/env bash
# ssh-content/_lib.sh — shim that loads the plugin's shared library
# and defines the parse_args() this skill expects.
# Source it from action scripts; don't run it directly.
#
# Why ssh-content shares the same ssh-lib.sh as ssh-deploy and
# ssh-download: all three read the same `.deploy/ssh.json` file, so
# every helper that touches that config (SSH command building, db
# args, remote_path) is identical across them. Skill-specific behavior
# lives in the action scripts, not here.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../shared/ssh-lib.sh
source "${LIB_DIR}/../../../shared/ssh-lib.sh"

# Flags recognized by ssh-content action scripts:
#   --config <path>       .deploy/ssh.json (required)
#   --action <verb>       for write.sh: item:create, item:update, etc.
#   --target <name>       type (for items) or page key (for pages)
#   --slug <slug>         slug-or-id (for item updates/get/delete)
#   --tables <list>       for backup.sh, comma-separated table list
#   --confirm             explicit confirmation for destructive ops
#   --dry-run             pass through to bin/nano for validation only
#   --json-stdin          write.sh reads JSON payload from its OWN stdin
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
