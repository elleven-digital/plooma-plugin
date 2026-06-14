#!/usr/bin/env bash
# Update Plooma core/engine on remote: rsync core/, public/, bin/, migrations/
# (NOT theme, NOT storage, NOT .env), then run `php bin/plooma migrate`.
# Refuses if Plooma isn't already installed at target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

parse_args "$@"

build_ssh_args
remote_path=$(remote_base_path)
app_url=$(cfg_get '.site.url')
app_url="${app_url%/}"

step "update-cms → ${ssh_target}:${remote_path}"

# --- Refuse if target is empty ---
state=$("${ssh_args[@]}" "test -f '${remote_path}/core/Bootstrap.php' && echo EXISTS || echo EMPTY" 2>&1)
if [[ "$state" != "EXISTS" ]]; then
    err "Plooma não detectado em ${remote_path}."
    err "update-cms só roda em instalações existentes. Use init.sh para o primeiro deploy."
    exit 1
fi
ok "Plooma detected — proceeding"

# --- Refuse if local migrations/ is missing ---
# update-cms ships engine code AND the migrations that go with it. If the
# local folder is missing, the server would receive newer core/ files
# without the matching schema migrations, leaving the DB out of sync with
# the code. Worse: with --delete, an empty/missing local folder could wipe
# the migrations the server has accumulated. Refuse loudly instead.
if [[ ! -d "./migrations" ]]; then
    err "Local migrations/ folder not found."
    err ""
    err "This script needs to push the migrations alongside core/ to keep"
    err "the server's DB schema in sync with the engine code being deployed."
    err ""
    err "If you have an older Plooma install where the install/upgrade skill"
    err "deleted migrations/ after running them, restore the folder:"
    err "  git checkout HEAD -- migrations/"
    err ""
    err "Or run plooma:upgrade — current versions of that skill keep"
    err "migrations/ in place so this script always has what it needs."
    exit 1
fi

# --- Rsync engine ---
# Flat layout: engine lives in core/, bin/, migrations/ subdirs PLUS index.php
# at the root. We rsync each subdir with --delete scoped to itself (safe —
# theme/ and storage/ are at root, untouched). We separately rsync the
# Plooma-shipped root files: index.php (entry), .htaccess.example +
# robots.txt.example (templates). Live .htaccess and robots.txt are
# user-customized and intentionally not synced.
step "Syncing engine dirs and root files"
rsh=$(rsync_remote_shell)
rsync_dest=$(rsync_target_for "$remote_path")

for sub in core bin migrations; do
    if [[ ! -d "./$sub" ]]; then
        warn "Local ./$sub not found — skipping"
        continue
    fi
    step "  rsync ${sub}/"
    rsync -avz --delete \
        --exclude='.DS_Store' \
        -e "$rsh" \
        "./${sub}/" "${rsync_dest}/${sub}/" >&2 || die "rsync failed for ${sub}/"
done

step "  rsync root engine files (index.php + .example templates)"
root_files=()
for f in index.php .htaccess.example robots.txt.example; do
    [[ -f "./$f" ]] && root_files+=("./$f")
done
if (( ${#root_files[@]} > 0 )); then
    rsync -avz \
        -e "$rsh" \
        "${root_files[@]}" "${rsync_dest}/" >&2 || die "rsync failed for root engine files"
fi
ok "Engine synced"

# CRITICAL: live .htaccess, robots.txt, .env, theme/, storage/ are NOT touched.
# If Plooma core ships a new .htaccess.example, the user can manually merge
# changes into their live .htaccess (they're gitignored — not auto-synced).

# --- Run migrations ---
step "Running php bin/plooma migrate"
mig_out=$("${ssh_args[@]}" "cd '${remote_path}' && php bin/plooma migrate 2>&1" || true)
echo "$mig_out" | sed 's/^/  /' >&2
if echo "$mig_out" | grep -qiE "error|fatal"; then
    err "Migration encountered errors. Review output above."
    exit 1
fi
ok "Migrations OK"

# --- Verify site still serves ---
step "Verifying ${app_url}"
http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -L "${app_url}/" || echo 000)
if [[ "$http_code" == "200" ]]; then
    ok "HTTP 200 OK"
else
    warn "HTTP ${http_code} — check the site manually: ${app_url}"
fi

echo
ok "update-cms complete."
echo
echo "  Site:    ${app_url}"
echo "  Path:    ${remote_path}"
echo "  Touched: core/ public/ bin/ migrations/ + ran migrate"
echo
echo "Não modificado: theme/, storage/uploads/, .env, banco (exceto migrations)."
