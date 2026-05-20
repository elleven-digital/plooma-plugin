#!/usr/bin/env bash
# Update Nano theme on remote: rsync theme/ (excluding install/, uploads, .env)
# and run `schema:validate` + `page:sync`.
# Refuses if Nano isn't already installed at target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

parse_args "$@"

build_ssh_args
remote_path=$(remote_base_path)
app_url=$(cfg_get '.site.url')
app_url="${app_url%/}"

step "update-theme → ${ssh_target}:${remote_path}"

# --- Refuse if target is empty ---
state=$("${ssh_args[@]}" "test -f '${remote_path}/core/Bootstrap.php' && echo EXISTS || echo EMPTY" 2>&1)
if [[ "$state" != "EXISTS" ]]; then
    err "Nano não detectado em ${remote_path}."
    err "update-theme só roda em instalações existentes. Use init.sh para o primeiro deploy."
    exit 1
fi
ok "Nano detected — proceeding"

# --- Rsync theme/ only ---
if [[ ! -d "./theme" ]]; then
    die "Local ./theme directory not found"
fi

step "Syncing theme/"
rsh=$(rsync_remote_shell)
rsync_dest=$(rsync_target_for "$remote_path")

# Exclude:
#   install/seed.php  — already ran on init, no need to re-ship
#   theme/storage/    — uploads live there in some setups; never overwrite
#   *.bak, .DS_Store  — local cruft
#   theme/*.php       — legacy nano-cms:theme-convert leftover files at theme root
excludes=(
    --exclude='install/seed.php'
    --exclude='storage/'
    --exclude='*.bak'
    --exclude='.DS_Store'
    --exclude='*.swp'
    --exclude='/*.php'
)

# User-provided extras
while IFS= read -r ex; do
    [[ -n "$ex" ]] && excludes+=("--exclude=$ex")
done < <(jq -r '.rsync.theme_extra_excludes[]? // empty' "$CONFIG_PATH")

# rsync with --delete scoped to theme/ — this removes templates/partials/etc
# that you've deleted locally, so the prod tree mirrors local. Safe because
# storage/uploads is OUTSIDE theme/ (it's at the project root).
rsync -avz --delete \
    "${excludes[@]}" \
    -e "$rsh" \
    "./theme/" "${rsync_dest}/theme/" >&2 || die "rsync failed for theme/"
ok "Theme files synced"

# --- Validate schema and sync pages ---
step "Running schema:validate"
sv_out=$("${ssh_args[@]}" "cd '${remote_path}' && php bin/nano schema:validate 2>&1" || true)
echo "$sv_out" | sed 's/^/  /' >&2
if echo "$sv_out" | grep -qiE "error|invalid|issue"; then
    err "schema:validate reported issues. Fix theme/site.json and re-run."
    exit 1
fi
ok "schema OK"

step "Running page:sync"
ps_out=$("${ssh_args[@]}" "cd '${remote_path}' && php bin/nano page:sync 2>&1" || true)
echo "$ps_out" | sed 's/^/  /' >&2
ok "page:sync done"

# --- Verify site still serves ---
step "Verifying ${app_url}"
http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -L "${app_url}/" || echo 000)
if [[ "$http_code" == "200" ]]; then
    ok "HTTP 200 OK"
else
    warn "HTTP ${http_code} — check the site manually: ${app_url}"
fi

echo
ok "update-theme complete."
echo
echo "  Site:    ${app_url}"
echo "  Path:    ${remote_path}"
echo "  Touched: theme/ + ran schema:validate + page:sync"
echo
echo "Não modificado: core/, storage/uploads/, .env, conteúdo das páginas no banco."
echo "(page:sync só adiciona páginas novas e atualiza metadados — não apaga conteúdo do editor.)"
