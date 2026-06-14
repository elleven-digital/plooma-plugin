---
name: upgrade
description: Upgrade Plooma (formerly Plooma CMS) in an existing project to the latest version (or a specific version) from elleven-digital/plooma. Uses the manifest+tarball model — reads `.plooma-version` to know the current version, hits the GitHub tags API for the latest, downloads the tarball, replaces only the engine paths declared in `engine-manifest.json`, runs new migrations, and updates `.plooma-version`. Strictly preserves user content (`theme/`, `storage/`, `.env`, the live `.htaccess` and `robots.txt`, `.deploy/`, `.claude/`, and any random files the user added). Does NOT depend on git — works on any machine that has the project, regardless of whether it was originally installed there or downloaded from a server via plooma:ssh-download. Use this skill whenever the user wants to update an installed Plooma project — phrases like "atualiza o plooma cms desse projeto", "puxa o update mais recente do plooma", "upgrade plooma para a última versão", "tem versão nova do plooma-cms?", "rode update do plooma aqui", "update the plooma-cms engine in this project", "instala a versão v1.2.3 nesse projeto" (if a specific version is wanted, pass --version=vX.Y.Z). Triggers in Portuguese and English. Always operates inside an existing Plooma project (must have `core/Bootstrap.php`). Do NOT use for: (a) fresh install — that's plooma:install (downloads from scratch), (b) theme conversion — that's plooma:theme-convert, (c) running specific CLI commands like `bin/plooma migrate` standalone (the user just wants to run the command, not upgrade the engine), (d) editing site.json or content. Mentioning "plooma" alone does NOT trigger — only explicit upgrade/update intent does.
---

# Upgrade Plooma in place

This skill brings a Plooma project up to the latest version (or any specific version) using the manifest+tarball model. It does NOT use git on the user's machine — Plooma is treated as a versioned dependency, not a fork.

## Goal

By the end:
- Engine files (per `engine-manifest.json`) match the target version (default: latest tag)
- New database migrations from the upgrade have been applied
- `.plooma-version` reflects the new version
- **Untouched**: user content (`theme/`, `storage/`), live config (`.env`, `.htaccess`, `robots.txt`), `.deploy/`, `.claude/`, and any custom files/folders the user added

## How this works at 30,000 ft

Three things make this skill possible without any persistent git in the project:

1. **`.plooma-version`** — a small JSON file at the project root that records the version currently installed. Written by `plooma:install` and updated by this skill. Travels with the project (gets deployed via `plooma:ssh-deploy`, downloaded back via `plooma:ssh-download`).

2. **GitHub tags API** — `https://api.github.com/repos/elleven-digital/plooma/tags` lists all release tags. The first item is the most recent. Comparison is just strings.

3. **Release tarballs** — `https://github.com/elleven-digital/plooma/archive/refs/tags/<tag>.tar.gz` is a static URL that GitHub serves for any tag. We download, extract, and selectively copy the engine paths.

Combined, these three give us "what version am I", "what version exists", and "how do I get that version's files" — all without git on the user's machine.

## Behavior overview

```
0. Pre-flight  — verify project is a Plooma install
1. Detect      — read .plooma-version (or migrate from legacy .git/ install)
2. Resolve     — fetch latest version (or use --version=X if specified)
3. Compare     — if already current, exit cleanly
4. Confirm     — show changelog + plan, get user OK
5. Fetch       — download tarball of target version
6. Apply       — rsync engine_paths from tarball to project
7. Migrate     — bin/plooma migrate (apply new schema)
8. Cleanup     — apply post_install_cleanup from manifest
9. Mark        — update .plooma-version
10. Report     — summary + new version + how to roll back
```

## Phase 0 — Pre-flight check

1. **Confirm we're in a Plooma install.** Check for `core/Bootstrap.php` and `bin/plooma`. If missing, abort with: "Não detectei uma instalação do Plooma aqui (faltam `core/Bootstrap.php` e/ou `bin/plooma`). Use a skill `plooma:install` para uma instalação nova."

2. **Confirm the system has required tools**: `curl`, `tar`, `jq`, `rsync`. These are standard on macOS/Linux. If missing, tell the user to install them.

## Phase 1 — Detect current version

Three possible states:

### State A — `.plooma-version` exists (modern install)

Read it:

```bash
CURRENT=$(jq -r '.version' .plooma-version)
SOURCE_REPO=$(jq -r '.source_repo // "elleven-digital/plooma"' .plooma-version)
```

Easy path. Continue to Phase 2.

### State B — `.git/` exists, no `.plooma-version` (legacy install)

This is a project installed before the manifest+tarball model. Two sub-cases:

- **`core/VERSION` exists** (manifest-aware Plooma, just no `.plooma-version` yet because user installed pre-skill update): derive version from `core/VERSION`. Offer to migrate:

  > "Detectei uma instalação legada — tem `.git/` mas não `.plooma-version`. A versão atual (de `core/VERSION`) é `<X>`. Posso migrar pro modelo novo (escrever `.plooma-version`, remover `.git/`) e seguir com o upgrade? `(y/N)`"

  On yes: write `.plooma-version` with version from `core/VERSION`, `rm -rf .git/`, continue.

- **`core/VERSION` doesn't exist** (very old install, pre-v1.0.0): we can't determine the exact starting version, but we CAN still upgrade — by treating it as "version unknown, upgrade to latest". The manifest+tarball flow does the right thing here: engine_paths get overwritten from the new tarball, user content is preserved per the manifest. Offer:

  > "Esta instalação é anterior ao versionamento do Plooma (não tem `core/VERSION`). Posso fazer um upgrade direto pra `<latest>` mesmo assim — vou:
  >   - Tratar como 'version unknown' → atualiza pra latest
  >   - Substituir os engine_paths do manifest novo (`core/`, `bin/`, `migrations/`, `index.php`, etc.)
  >   - Preservar `theme/`, `storage/`, `.env`, `.htaccess`, `robots.txt`, `.deploy/`, `.claude/`
  >   - Rodar migrations pendentes (o `migrate_log` no banco define o que ainda falta aplicar)
  >   - Remover `.git/` (você passa pro modelo versionado)
  >
  > ⚠️  **Atenção**: se você modificou arquivos de `core/`, `bin/`, ou outras paths declaradas como engine_paths, essas mudanças serão perdidas. Customizações devem viver em `theme/` ou em hooks; nunca direto em `core/`. Continuar? `(y/N)`"

  On yes: set CURRENT="unknown" (used pra mensagens de log), proceed with normal manifest+tarball flow targeting the latest tag. After successful upgrade, write `.plooma-version` and remove `.git/`.

### State C — Neither `.plooma-version` nor `.git/` (orphan project)

Project came via something other than `plooma:install` (e.g., copied from somewhere, downloaded as zip). It IS a Plooma install (passed Phase 0) but has no version metadata.

Same approach as State B sub-case "very old" — offer to upgrade-as-if-unknown. The same warning about engine_paths customizations applies. Difference: no `.git/` to remove.

### Common state-B/C migration logic

When migrating a legacy/orphan project, after determining "treat as unknown → latest", continue normally with Phases 2–10. Two small differences from the standard flow:

1. **In Phase 4 (Confirm):** show the changelog as "from unknown" instead of "from <version>". The list of new commits won't be available (we don't know where to start the comparison), so omit that section. Just show the engine_paths that will change.

2. **In Phase 9 (Mark new version):** write `.plooma-version` with `previous_version: "unknown (migrated)"` so the upgrade history is honest about what happened.

3. **After Phase 9 (only for State B with `.git/`):** `rm -rf .git/`. Tell the user this happened.

This unblocks the most common real-world scenario: someone has a Plooma project installed before v1.0.0 (the first versioned release) and wants the latest engine + new features.

## Phase 2 — Resolve target version

If user passed `--version=vX.Y.Z`, use that. Otherwise hit the tags API:

```bash
TARGET=$(curl -fsS "https://api.github.com/repos/${SOURCE_REPO}/tags" \
  | jq -r '.[0].name')
```

Validate that the tag exists by checking the corresponding tarball URL returns 200:

```bash
curl -fsLI -o /dev/null \
  "https://github.com/${SOURCE_REPO}/archive/refs/tags/${TARGET}.tar.gz" \
  || die "Tag ${TARGET} not found at ${SOURCE_REPO}."
```

## Phase 3 — Compare

```bash
if [[ "$CURRENT" == "$TARGET" ]]; then
    echo "Plooma já está em $CURRENT. Nada a atualizar."
    exit 0
fi
```

For curiosity, you can also fetch the commits-between view (only useful when both are tags on the same upstream):

```bash
COMPARE=$(curl -fsS "https://api.github.com/repos/${SOURCE_REPO}/compare/${CURRENT}...${TARGET}")
```

Save it for Phase 4. The `commits` array has each commit's message, useful for showing the changelog.

## Phase 4 — Confirm with user

Show a clear summary before doing anything destructive:

```
Upgrade plan:
  De:  v1.4.2  (instalado em 2026-04-29)
  Pra: v1.5.0  (3 commits novos)

  Mudanças:
    - feat: adiciona campo de redirect em pages
    - fix: SQL injection em FormSubmission::byEmail
    - chore: bump min PHP para 8.2.5

  Vai SUBSTITUIR (engine paths do manifest):
    core/, bin/, migrations/, index.php
    .htaccess.example, robots.txt.example, nginx.conf.example
    .env.example, README.md, AGENTS.md
    .gitignore, engine-manifest.json

  Vai PRESERVAR (intocado):
    theme/, storage/    (seu conteúdo)
    .env                (seus secrets)
    .htaccess, robots.txt   (suas configs live)
    .deploy/, .claude/  (configs locais)
    <untracked files seen>

  Vai RODAR:
    bin/plooma migrate    (novas migrations, se houver)

Continuar? (y/N)
```

Wait for explicit "y" or equivalent.

## Phase 5 — Fetch tarball

```bash
TMPDIR=$(mktemp -d)
TARBALL="${TMPDIR/plooma-${TARGET}.tar.gz"
TARBALL_URL="https://github.com/${SOURCE_REPO}/archive/refs/tags/${TARGET}.tar.gz"

curl -fSL "$TARBALL_URL" -o "$TARBALL" || die "Failed to download $TARBALL_URL"

tar -xzf "$TARBALL" -C "$TMPDIR/"
EXTRACTED=$(find "$TMPDIR" -maxdepth 1 -type d -name "*-${TARGET#v}*" | head -1)

[ -d "$EXTRACTED" ] || die "Tarball extracted but expected directory not found in $TMPDIR"
[ -f "$EXTRACTED/engine-manifest.json" ] || die "Tarball doesn't contain engine-manifest.json — wrong version?"
```

## Phase 6 — Apply engine paths

Read the manifest from the extracted tarball (NOT from the local project — the new manifest may have added or removed paths versus the old one):

```bash
NEW_MANIFEST="$EXTRACTED/engine-manifest.json"

# Iterate engine_paths from the new manifest
jq -r '.engine_paths[]' "$NEW_MANIFEST" | while read -r path; do
    src="$EXTRACTED/$path"
    dst="./$path"

    if [[ "$path" == */ ]]; then
        # Directory — use rsync with --delete to mirror
        rsync -a --delete "$src" "$(dirname "$dst")/"
    elif [[ -f "$src" ]]; then
        # File — straight copy
        cp -f "$src" "$dst"
    else
        echo "  warn: $path declared in manifest but not in tarball; skipping" >&2
    fi
done
```

The `--delete` on directories is crucial: if the new version REMOVED a file from `core/` (e.g., a deprecated helper), the local copy should also lose it. Otherwise local stays with stale code that no longer exists upstream.

## Phase 7 — Run migrations

```bash
./bin/plooma migrate
```

Watch for:
- "Nothing to migrate." → no new schema; OK
- "Applied: <name>" → new migrations ran successfully
- Any error → abort and tell user: engine files are at the new version, migrations failed. Suggest running `./bin/plooma migrate:status` to see what's pending and `./bin/plooma migrate` again after fixing the DB issue.

## Phase 8 — Post-install cleanup

Two-part cleanup:

### 8a. Manifest-declared cleanup

The new manifest's `post_install_cleanup` lists files that should always be removed after a successful upgrade (e.g., `INSTALL.md` — install instructions don't apply once installed):

```bash
jq -r '.post_install_cleanup[]?' "$NEW_MANIFEST" | while read -r path; do
    [ -f "./$path" ] && rm -f "./$path"
done
```

### 8b. Conditional `.example` template cleanup

`plooma:install` removes `.htaccess.example` and `robots.txt.example` from a fresh install once their live counterparts (`.htaccess`, `robots.txt`) exist. The upgrade flow has to mirror that — otherwise every upgrade re-introduces those `.example` files (they're in `engine_paths` so the tarball brings them back) and the project accumulates dead-weight templates over time.

The "only remove if live counterpart exists" guard is the same as `plooma:install`: never leave the project with neither the template nor the live config.

```bash
[ -f .htaccess ] && rm -f .htaccess.example
[ -f robots.txt ] && rm -f robots.txt.example
```

Note: `nginx.conf.example` is handled unconditionally by Phase 8a via the manifest's `post_install_cleanup` array — Plooma is officially Apache-only, so the nginx template gets removed on every upgrade just like on a fresh install. No extra logic needed here.

## Phase 9 — Mark new version

Update `.plooma-version`:

```bash
INSTALLED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > .plooma-version <<EOF
{
  "version": "${TARGET}",
  "installed_at": "${INSTALLED_AT}",
  "previous_version": "${CURRENT}",
  "source_repo": "${SOURCE_REPO}",
  "manifest_url": "https://raw.githubusercontent.com/${SOURCE_REPO}/${TARGET}/engine-manifest.json"
}
EOF
```

Note `previous_version` — useful for rollback narratives.

Then cleanup tmp:

```bash
rm -rf "$TMPDIR"
```

## Phase 10 — Report

```
✓ Plooma atualizado.

  De:  v1.4.2
  Pra: v1.5.0  (3 commits)

  Migrations aplicadas: 2026_05_01_redirect_field
  Files cleaned up:     INSTALL.md
  Preservado:           .env, .htaccess, robots.txt, theme/, storage/, .deploy/, .claude/

  Próximo:
    - Teste o site: abra / e /admin/login
    - Se algo quebrou: rollback é simples, rode:
        plooma:upgrade --version=v1.4.2
      (engine volta; seu DB e conteúdo seguem intactos)
```

Show the previous version as the explicit rollback command — it's exactly what `--version=` does in this skill.

## Edge cases

- **`engine-manifest.json` mudou entre versões**: novos engine_paths são copiados; paths que sumiram da v nova permanecem no projeto (não temos como saber que eles deveriam sumir). Avisar o usuário se diferença for grande.

- **Tarball corrompido / network drop mid-extract**: `tar -xzf` falha → `die` mantém o projeto inalterado (não fizemos nada destrutivo ainda).

- **rsync falha mid-copy** (ex.: filesystem cheio): caso ruim. O `core/` pode ficar parcialmente atualizado. Recomendar rodar de novo após resolver — rsync resumível por design.

- **Migração que falha**: engine files já estão no estado novo, mas DB não. Rodar `bin/plooma migrate:status` mostra pendentes; `bin/plooma migrate` pode ser reexecutado depois.

- **Usuário tem fork**: `--repo=usuario/fork-plooma` substitui SOURCE_REPO no momento. Fork precisa ter tags + `engine-manifest.json` na raiz.

- **`--version=v0.X.Y` muito antigo**: pode não ter `engine-manifest.json` (vem em v1.0.0+). Skill detecta a ausência no Phase 5 e aborta com hint pra usar versão >= v1.0.0.

- **Downgrade**: tecnicamente suportado (passa `--version` pra versão anterior), MAS migrations não têm "down" — schema do DB pode ficar à frente do código. Aceito como tradeoff explícito; user fica avisado pra fazer DB clone se precisar.

## What this skill does NOT do

- Touch `theme/`, `storage/`, `.env`, live `.htaccess`/`robots.txt`, ou qualquer arquivo NÃO listado em `engine_paths` do manifest novo
- Force-merge mudanças locais em arquivos engine — se o usuário modificou `core/Bootstrap.php` localmente, essas mudanças são perdidas. (Recomendação: extensions/customizations devem ir em `theme/` ou via hooks futuros, não direto em `core/`)
- Usar git em momento nenhum — nem na máquina do user, nem nada
- Rodar backup automático do DB — assume que o user tem seu próprio processo de backup
- Resolver `latest` de forma dinâmica que pega `main` HEAD (precisa ser uma tag explícita; pra ter uma tag por commit, configure GitHub Action no upstream)

## Variants the user might phrase

All of these should trigger and execute:

**Português:**
- "atualiza o plooma nesse projeto"
- "tem versão nova do plooma cms? roda aqui"
- "instala a v1.2.5 nesse projeto" (passa `--version=v1.2.5`)
- "rollback pra v1.4.0" (passa `--version=v1.4.0`)
- "upgrade plooma cms"

**English:**
- "update plooma-cms in this project"
- "upgrade to latest plooma"
- "install v1.5.0 of plooma here"
- "is there a new plooma version?"

If the user wants to upgrade only to a specific commit (not a tagged release), they need to specify that explicitly. Default behavior is "latest tagged release."
