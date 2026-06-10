#!/usr/bin/env bash
# Preflight checks for ellev:ssh-download.
#
# Validates everything that must be true before the destructive download
# operation runs. Exits 0 if all good, non-zero otherwise (with the failing
# check identified). Doesn't modify anything anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

parse_args "$@"
require_config

# Resolve SSH command from config — sets SSH_CMD and SSH_TARGET
eval "$(resolve_ssh_cmd)"

REMOTE_PATH=$(cfg_get '.ssh.remote_path')
REMOTE_DB_HOST=$(cfg_get '.db.host')
REMOTE_DB_NAME=$(cfg_get '.db.name')
REMOTE_DB_USER=$(cfg_get '.db.user')
REMOTE_DB_PASS=$(cfg_get '.db.password')
LOCAL_DB_HOST=$(cfg_get '.local.db_host')
LOCAL_DB_NAME=$(cfg_get '.local.db_name')
LOCAL_DB_USER=$(cfg_get '.local.db_user')
LOCAL_DB_PASS=$(cfg_get '.local.db_password')

# ─────────────────────────────────────────────────────────────────────────────
# Check 1: SSH connects
# ─────────────────────────────────────────────────────────────────────────────
log_step "1/5 SSH connects to ${SSH_TARGET}"
if ! eval "$SSH_CMD" "$SSH_TARGET" "echo ok" 2>/tmp/preflight-ssh.err >/dev/null; then
    log_err "SSH connection failed:"
    cat /tmp/preflight-ssh.err >&2
    rm -f /tmp/preflight-ssh.err
    echo
    echo "Possible fixes:" >&2
    echo "  • Verify the SSH alias / host / user / port" >&2
    echo "  • Confirm your SSH key is loaded: ssh-add -l" >&2
    echo "  • For passwordless first-time access: ssh-copy-id <target>" >&2
    exit 1
fi
log_ok "SSH connects"
rm -f /tmp/preflight-ssh.err

# ─────────────────────────────────────────────────────────────────────────────
# Check 2: Remote has Ellev at the configured path
# ─────────────────────────────────────────────────────────────────────────────
log_step "2/5 Remote has Ellev at ${REMOTE_PATH}"
remote_check=$(eval "$SSH_CMD" "$SSH_TARGET" "test -f '${REMOTE_PATH}/core/Bootstrap.php' && echo HAS_NANO || echo NO_NANO" 2>/dev/null || echo "NO_NANO")
if [[ "$remote_check" != "HAS_NANO" ]]; then
    log_err "Não encontrei Ellev em ${REMOTE_PATH} no servidor."
    echo "  Verifique o caminho — execute no servidor: ls ${REMOTE_PATH}" >&2
    exit 1
fi
log_ok "Ellev found at ${REMOTE_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# Check 3: Remote DB is accessible
# ─────────────────────────────────────────────────────────────────────────────
log_step "3/5 Remote DB connects (${REMOTE_DB_NAME} @ ${REMOTE_DB_HOST})"
# Build the mysql command. Quote the password to handle special chars.
remote_mysql_cmd="mysql -u'${REMOTE_DB_USER}' -p'${REMOTE_DB_PASS}' -h'${REMOTE_DB_HOST}' '${REMOTE_DB_NAME}' -e 'SELECT 1' >/dev/null 2>&1"
if ! eval "$SSH_CMD" "$SSH_TARGET" "$remote_mysql_cmd"; then
    log_err "Não consegui conectar no DB remoto."
    echo "  Verifique db.host / db.name / db.user / db.password no .deploy/ssh.json" >&2
    echo "  Teste manualmente: ssh ${SSH_TARGET} \"mysql -u${REMOTE_DB_USER} -p ${REMOTE_DB_NAME} -e 'SELECT 1'\"" >&2
    exit 1
fi
log_ok "Remote DB reachable"

# ─────────────────────────────────────────────────────────────────────────────
# Check 4: Local DB is accessible
# ─────────────────────────────────────────────────────────────────────────────
log_step "4/5 Local DB connects (${LOCAL_DB_NAME} @ ${LOCAL_DB_HOST})"
local_mysql_args=(-u"${LOCAL_DB_USER}" -h"${LOCAL_DB_HOST}")
[[ -n "$LOCAL_DB_PASS" ]] && local_mysql_args+=(-p"${LOCAL_DB_PASS}")

if ! mysql "${local_mysql_args[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
    log_err "Não consegui conectar no MySQL local."
    echo "  Verifique local.db_host / local.db_user / local.db_password no .deploy/ssh.json" >&2
    echo "  Teste manualmente: mysql -u${LOCAL_DB_USER} -h${LOCAL_DB_HOST} -p" >&2
    exit 1
fi
log_ok "Local DB reachable"

# ─────────────────────────────────────────────────────────────────────────────
# Check 5: Local DB user has DROP/CREATE privileges
# ─────────────────────────────────────────────────────────────────────────────
log_step "5/5 Local DB user has DROP/CREATE privileges"
priv_check_db="__nano_priv_check_$$"
if ! mysql "${local_mysql_args[@]}" -e "CREATE DATABASE IF NOT EXISTS \`${priv_check_db}\`; DROP DATABASE \`${priv_check_db}\`;" 2>/tmp/preflight-priv.err; then
    log_err "Usuário local '${LOCAL_DB_USER}' não tem privilégios pra DROP/CREATE database."
    echo "  Output do MySQL:" >&2
    cat /tmp/preflight-priv.err >&2
    rm -f /tmp/preflight-priv.err
    echo "  Esta skill PRECISA dropar e recriar o DB local. Use um usuário com privilégios maiores," >&2
    echo "  ou peça pro DBA local te dar GRANT DROP, CREATE no banco." >&2
    exit 1
fi
log_ok "Local DB user can DROP/CREATE"
rm -f /tmp/preflight-priv.err

# ─────────────────────────────────────────────────────────────────────────────
# All clear
# ─────────────────────────────────────────────────────────────────────────────
echo
log_ok "All preflight checks passed. Safe to proceed with download."
exit 0
