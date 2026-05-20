#!/usr/bin/env bash
# Preflight: verify SSH connectivity, remote DB connectivity, and target state.
# Run during first-time setup validation, or any time the user wants to confirm
# the config still works before deploying.
#
# Exit code 0 = all checks pass. Non-zero = something needs fixing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

parse_args "$@"

build_ssh_args
remote_path=$(remote_base_path)

step "Preflight against ${ssh_target}:${remote_path}"

# 1. SSH connectivity
step "1/4 SSH key auth"
if ! "${ssh_args[@]}" -o ConnectTimeout=10 "echo OK" >/dev/null 2>&1; then
    err "SSH failed. Check key auth (ssh-copy-id user@host -p PORT) and ssh.* config."
    exit 1
fi
ok "SSH OK"

# 2. Remote DB connectivity
step "2/4 Remote MySQL connection"
db_args=$(remote_db_args)
db_test=$("${ssh_args[@]}" "mysql ${db_args} -e 'SELECT 1' 2>&1" || true)
if echo "$db_test" | grep -q "Access denied\|Unknown database\|Can't connect"; then
    err "MySQL connection failed: $db_test"
    err "Verify db.{name,user,password} in config — these come from hPanel → Databases."
    exit 1
fi
ok "Remote MySQL OK"

# 3. Remote target dir exists or is creatable
step "3/4 Remote directory"
mk_test=$("${ssh_args[@]}" "mkdir -p '${remote_path}' && [ -d '${remote_path}' ] && echo OK || echo FAIL" 2>&1)
if [[ "$mk_test" != "OK" ]]; then
    err "Cannot access or create ${remote_path}: $mk_test"
    exit 1
fi
ok "Remote dir reachable: ${remote_path}"

# 4. Local DB dump-ability
step "4/4 Local mysqldump"
dump_cmd=$(local_db_dump_cmd)
if ! eval "$dump_cmd --no-data --skip-comments 2>/dev/null | head -3" >/dev/null; then
    err "Local mysqldump failed. Check local.{db_host,db_name,db_user,db_password}."
    exit 1
fi
ok "Local DB dumpable"

echo
ok "Preflight PASS — config is valid."

# Bonus: report target state so the caller knows whether to offer init or updates.
state=$("${ssh_args[@]}" "test -f '${remote_path}/core/Bootstrap.php' && echo EXISTS || echo EMPTY" 2>/dev/null)
echo
echo "Target state: ${state}"
