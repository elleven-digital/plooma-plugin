---
name: install
description: Install Plooma (formerly Plooma CMS) (elleven-digital/plooma) into the current directory FROM SCRATCH. Downloads the latest released version as a tarball, gathers DB and admin credentials interactively, writes `.env`, runs the bundled installer (migrations + initial user + per-project files), and records the installed version in `.plooma-version` so future upgrades work without depending on git. Use this skill whenever the user wants a fresh install — phrases like "instala o plooma aqui", "set up plooma-cms in this folder", "bootstrap plooma", "create a new plooma project", "i just want a working plooma-cms here", "instalar o plooma nessa pasta". Triggers in Portuguese and English. Do NOT use when: (a) converting static HTML/PHP into a theme — that's plooma:theme-convert, (b) updating/upgrading an existing Plooma install to a newer version, (c) running specific CLI commands like `bin/plooma migrate` or `page:sync` on a project that's already installed, (d) answering reference questions about Plooma's schema, helpers, fields, options, or features. Mentioning Plooma-specific keywords like "plooma", "site.json", or "field()" alone does NOT trigger this skill — only explicit setup/install/bootstrap intent does.
---

# Install Plooma

This skill installs Plooma into the current working directory. It's an interactive flow: download a versioned release tarball, gather config, configure, run installer, write `.plooma-version`, report back. **The project is left without a `.git/` of Plooma** — Plooma is a dependency, not a fork. Future upgrades use the tarball+manifest model (see `plooma:upgrade`).

## Goal of this skill

By the end, the user has:
- A working Plooma installation at the current directory (`./core/`, `./bin/`, `./index.php`, etc.)
- A populated `.env` with DB credentials
- A live database with migrations applied
- An initial admin user
- The per-project files (`.htaccess`, `robots.txt`) at the project root, copied from the `.example` templates
- A `.plooma-version` file recording the installed version (e.g., `v1.0.0`) for future upgrades
- A clean filesystem: `.htaccess.example`, `robots.txt.example`, and `INSTALL.md` are removed after a successful install. The `migrations/` folder is **kept** because future engine updates need to ship new migrations to remote servers
- **No `.git/` of Plooma** in the project. Plooma is a versioned dependency, not a fork in their codebase.

They should be able to log into `/admin/login` immediately after.

## Behavior overview

```
1. Pre-flight  — ensure folder is safe to install into
2. Fetch       — download release tarball from elleven-digital/plooma
3. Gather      — DB creds + initial admin (required), APP_URL (optional)
4. Write .env  — from .env.example template + answers
5. Install     — run ./bin/plooma install with credentials
6. Cleanup     — remove .example scaffolding and INSTALL.md
7. Version     — write .plooma-version with the installed version
8. Report      — login URL + next steps
```

Stop and ask the user before doing anything destructive. If something fails, do NOT leave partial state — clean up extracted files if config gathering or install fails before completion. Cleanup (step 6) only runs after install succeeds; on failure, leave the scaffolding in place so the user can debug or retry.

## Step 1 — Pre-flight check

Run `ls -la` in the current directory and reason about what's there:

- **If `core/Bootstrap.php` exists** → Plooma is already installed here. STOP. Tell the user: "Plooma appears to already be installed in this folder. Re-running install would overwrite files. Do you want to (a) abort, (b) wipe and reinstall, (c) run `plooma:upgrade` to bring it to the latest version, (d) just run `./bin/plooma install` to apply pending migrations on the existing install?" Wait for explicit confirmation.

- **If folder is empty** → ideal case, proceed. The tarball will extract straight into `./`.

- **If folder has non-Plooma files** (user's own project, an existing git repo of a different project, random files) → list them and ask: "This folder contains [files...]. Installing Plooma here will add Plooma's files alongside. Existing files won't be overwritten unless they collide with Plooma's tracked files (rare). Continue?" If they confirm, the tarball extracts into the same directory; collisions overwrite (warn the user explicitly about which files would collide before extracting).

- **If `.env` already exists** → ask before overwriting; offer to keep existing values.

## Step 2 — Fetch tarball

Resolve the version to install from the public release manifest (`releases.plooma.io/versions.json`). Default: the `latest` entry. Override via `--version=v1.2.3` for a specific version, or `--release-base-url=<url>` for a mirror.

```bash
RELEASE_BASE_URL="https://releases.plooma.io"   # default; override com --release-base-url=<url>

# 1. Manifesto de descoberta de versão (substitui a tags API do GitHub).
MANIFEST=$(curl -fsSL "${RELEASE_BASE_URL}/versions.json") || {
    echo "Não consegui buscar ${RELEASE_BASE_URL}/versions.json. Verifique a URL e a rede." >&2
    exit 1
}

# 2. Resolver versão alvo + url + sha256.
if [[ -n "$VERSION" ]]; then
    TAG="$VERSION"
else
    TAG=$(echo "$MANIFEST" | jq -r '.latest')
fi
ENTRY=$(echo "$MANIFEST" | jq -c --arg v "$TAG" '.versions[] | select(.version==$v)')
if [[ -z "$ENTRY" || "$ENTRY" == "null" ]]; then
    echo "Versão ${TAG} não está em ${RELEASE_BASE_URL}/versions.json." >&2
    echo "Disponíveis: $(echo "$MANIFEST" | jq -r '[.versions[].version] | join(", ")')" >&2
    exit 1
fi
URL=$(echo "$ENTRY" | jq -r '.url')
SHA256=$(echo "$ENTRY" | jq -r '.sha256')

# 3. Baixar o tarball.
TMPDIR=$(mktemp -d)
curl -fSL "$URL" -o "$TMPDIR/plooma.tar.gz" || {
    echo "Falha ao baixar ${URL}." >&2
    rm -rf "$TMPDIR"; exit 1
}

# 4. Verificar integridade (sha256 do manifesto). Mismatch = aborta —
#    não dependemos mais da confiança implícita do GitHub.
if command -v shasum >/dev/null 2>&1; then
    GOT=$(shasum -a 256 "$TMPDIR/plooma.tar.gz" | awk '{print $1}')
else
    GOT=$(sha256sum "$TMPDIR/plooma.tar.gz" | awk '{print $1}')
fi
if [[ "$GOT" != "$SHA256" ]]; then
    echo "FALHA de integridade em ${URL}" >&2
    echo "  esperado ${SHA256}" >&2
    echo "  obtido   ${GOT}" >&2
    rm -rf "$TMPDIR"; exit 1
fi

# 5. Extrair. O tarball envolve tudo em plooma-<version>/.
tar -xzf "$TMPDIR/plooma.tar.gz" -C "$TMPDIR/"
EXTRACTED=$(find "$TMPDIR" -maxdepth 1 -type d -name "plooma-*" | head -1)

# 6. Copiar o conteúdo pro diretório atual (sem a pasta-wrapper).
( cd "$EXTRACTED" && tar cf - . ) | tar xf -

# 7. Limpar.
rm -rf "$TMPDIR"

# 8. Verificar a extração.
[ -f core/Bootstrap.php ] && [ -f bin/plooma ] || {
    echo "Install falhou — core/Bootstrap.php ou bin/plooma não encontrados após extração." >&2
    exit 1
}

echo "Plooma ${TAG} baixado (sha256 verificado)"
```

Why tarball and not git clone:
- **No persistent `.git/` left in the project.** Plooma is a versioned dependency — having its git history in your project is conceptually backwards (you don't keep Composer's git in your PHP project either).
- **No git dependency** on the user's machine.
- **Versioned by design.** You always know exactly what version is going in.
- **Cross-machine reliable.** Same flow works whether the user is on the machine that originally installed it or coming fresh.

If the user passes `--release-base-url=<url>`, set `RELEASE_BASE_URL` to it (self-hosters / mirrors). The mirror must serve the same `versions.json` + tarball layout that `bin/release` produces. There is no GitHub fallback by design — the canonical source repo is private; `releases.plooma.io` is the single distribution endpoint.

The tarball Github gives us already excludes `.git/` — so there's nothing to clean up afterwards on that front.

## Step 3 — Gather config

**Use AskUserQuestion if available**, otherwise plain prompts. Group questions to avoid round-trips when the tool supports multiple questions per call.

### Required: database

Ask all 5 in one batch:

| Field | Default | Notes |
|---|---|---|
| `DB_HOST` | `localhost` | Most installs run DB on the same host. |
| `DB_PORT` | `3306` | Standard MySQL/MariaDB. |
| `DB_DATABASE` | (none) | Required. Will be created if missing. |
| `DB_USERNAME` | `root` (dev) | Required. Must have CREATE DATABASE if DB doesn't exist. |
| `DB_PASSWORD` | (empty allowed) | Required field, but empty value is valid for some local setups. |

### Required: initial admin user

| Field | Notes |
|---|---|
| `INITIAL_USER_EMAIL` | Required. Validate format (must contain `@` + a dot). |
| `INITIAL_USER_PASSWORD` | Required. Min 6 chars (Installer enforces this — it'll error if shorter). |
| `INITIAL_USER_NAME` | Default: "Admin". |

### Optional: production URL

```
APP_URL — production canonical URL (e.g. https://meusite.com.br).
Leave empty for dev/local — Plooma will auto-detect from the request host.
This is used by sitemap.xml and absolute_url() helpers.
```

### Mention but don't ask: SMTP

Tell the user: "SMTP for form emails is optional. Skipping for now — when you want forms to send email, edit `.env` and set `SMTP_HOST`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`."

## Step 4 — Write .env

The repo ships with `.env.example`. Read it, replace the placeholders with the user's answers, write to `.env`.

If the file doesn't exist (rare — repo should always have it), create from this template:

```env
APP_NAME="Plooma"
APP_URL="<answer or empty>"
APP_DEBUG=false
APP_TIMEZONE=America/Sao_Paulo
APP_LOCALE=pt-BR

DB_HOST=<answer>
DB_PORT=<answer>
DB_DATABASE=<answer>
DB_USERNAME=<answer>
DB_PASSWORD=<answer>

SESSION_NAME=nano_session
SESSION_LIFETIME=604800

SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_FROM=

INITIAL_USER_EMAIL=<answer>
INITIAL_USER_PASSWORD=<answer>
INITIAL_USER_NAME=<answer>
```

Quote values that contain spaces or special chars. Don't quote numeric values (PORT).

Make `.env` non-readable by web (the `.htaccess` blocks `.env` already, but set permissions):
```bash
chmod 0600 .env
```

## Step 5 — Run the installer

```bash
./bin/plooma install
```

Pass credentials via flags only if `INITIAL_USER_*` are NOT in `.env` (they should be, from step 4). The CLI reads env first, flags override.

Watch the output for:

- **"Database `X` … OK"** → DB created or already existed.
- **"Database … FAIL"** → wrong credentials or no permission to create. Do not write a broken state — go back to step 3, ask for corrected DB info, retry.
- **"Migrations: N applied"** → schema set up. If "MySQL version too old" or similar JSON-column errors appear, report: "Plooma requires MySQL 5.7+ or MariaDB 10.2+ (needs native JSON columns)."
- **"Project files initialized: + .htaccess + robots.txt"** → project file templates copied from the `.example` files into the project root. Expected on a fresh install.
- **"Initial user: <email>"** → admin created.
- **"✓ Installed."** → success.

## Step 6 — Clean up installation scaffolding

Once `bin/plooma install` reports success, a few files have served their purpose and only add clutter to the working project. Remove them so the user opens to a clean filesystem.

```bash
# Per-project file templates — only remove the .example if its live
# counterpart actually exists, otherwise we'd leave the project with
# neither the template nor the live config (broken state).
[ -f .htaccess ] && rm -f .htaccess.example
[ -f robots.txt ] && rm -f robots.txt.example

# Install doc — guidance for setting up; not relevant once setup is done.
rm -f INSTALL.md

# Nginx template — Plooma's installer only generates Apache config
# (.htaccess), not nginx server blocks. Plooma is officially Apache-only.
# Users on nginx have to configure their server block manually (the
# rewrite rule is just `try_files $uri $uri/ /index.php?$args;`) and
# the template here at the project root would never be read by nginx
# anyway (nginx config lives in /etc/nginx/, not the docroot).
rm -f nginx.conf.example

# .gitignore — the version shipped in the tarball is the upstream
# plooma-cms repo's own .gitignore, which ignores the wrong things for
# user projects (it ignores /theme/, /.htaccess, /robots.txt — exactly
# the files a project owner WANTS to commit). Leaving it in place
# would actively break `git init` on the project. If the user wants
# git, they create a .gitignore that fits THEIR project (commit theme,
# ignore .env, ignore /.deploy/, etc.).
rm -f .gitignore

# engine-manifest.json — install/upgrade machinery only. Both skills
# read the manifest from the tarball, never from the local copy, so
# the file sits dormant in the project after install. Worse: a user
# who edits the local copy expecting to customize upgrade behavior
# would get no effect (silently confusing). The `.plooma-version` file
# keeps `release_base_url` so `plooma:upgrade` knows where to pull from.
rm -f engine-manifest.json
```

**Important guards:**

- **Only run this step after install succeeded.** If install failed (DB error, migrations error, anything that left the project unusable), leave everything in place — the user may need to debug or rerun.
- **Never remove a `.example` template if the corresponding live file doesn't exist** (applies to `.htaccess.example` and `robots.txt.example`). That would leave the project with neither the template nor the live config — broken state. `nginx.conf.example` is removed unconditionally because there's no live counterpart on Apache hosts (the vast majority). `.gitignore` is also removed unconditionally — the upstream version is for the Plooma repo itself (ignoring `/theme/`, `/.htaccess`, etc.) and would actively harm a user project's git setup; better no `.gitignore` than a wrong one. `engine-manifest.json` is install/upgrade machinery (read from the tarball, not the local copy) — keeping it in the project would only confuse users into editing it expecting customization.
- **Don't remove `.env.example`.** It's the canonical reference for all configurable env vars and stays useful long after install (when the user wants to add SMTP, change APP_URL, etc.).
- **Don't remove `migrations/`.** The applied schema lives in the DB, but the migration FILES still need to stay around so deploys (`plooma:ssh-deploy update-cms`) can ship new migrations to remote servers. Removing them locally would leave the project unable to push schema changes to prod when Plooma upstream releases new migrations later.

If any removal fails (permissions, file already gone), don't error — just note it and continue. The cleanup is housekeeping, not load-bearing.

### Why migrations/ stays around

Earlier versions of this skill removed `migrations/` after install on the theory that "the schema lives in the DB now." That backfired in the deploy flow: `plooma:ssh-deploy update-cms` rsyncs `core/`, `bin/`, AND `migrations/` to the server, then runs `bin/plooma migrate` remotely to apply pending schema changes. Without local migration files, deploys would silently push core changes that depend on schema that never arrives. Worse, with `rsync --delete`, an empty local `migrations/` could wipe the migrations the server already has.

Keeping the folder is the simpler, safer choice. It's a few files of git-tracked SQL/PHP — costs nothing in confusion or disk and removes a whole class of foot-gun.

## Step 7 — Write .plooma-version

After cleanup succeeds, record what version was just installed. This is the file that future `plooma:upgrade` reads to know "where you are" — it's how the project tracks its Plooma version once `.git/` is gone.

```bash
# A versão vem de core/VERSION (que o tarball trouxe).
# .plooma-version é metadado do projeto escrito pelas skills install/upgrade.
INSTALLED_VERSION=$(cat core/VERSION 2>/dev/null || echo "unknown")
INSTALLED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > .plooma-version <<EOF
{
  "version": "${INSTALLED_VERSION}",
  "installed_at": "${INSTALLED_AT}",
  "release_base_url": "${RELEASE_BASE_URL}"
}
EOF
```

The `release_base_url` records where this project pulls releases from, so `plooma:upgrade` reads it straight from `.plooma-version` (the engine manifest is removed post-install, so it can't come from there). A project installed from a mirror keeps upgrading from that mirror.

`.plooma-version` lives at the project root and **goes along with the project** when deployed via `plooma:ssh-deploy` or downloaded via `plooma:ssh-download`. So any machine that has the project knows what version it's running. (If the user runs `git init` later, they'll likely want to commit this file — it's part of the project's identity, not a secret.)

## Step 8 — Report success

Print a summary the user can act on:

```
✓ Plooma installed at <pwd>

Login:
  http://localhost/admin/login   (dev — adjust path/host for your setup)
  email: <INITIAL_USER_EMAIL>

Cleanup:
  Removed .htaccess.example, robots.txt.example, and INSTALL.md
  (templates are in place at the project root; INSTALL doc is no longer needed).
  Kept migrations/ — needed when deploying engine updates to remote servers.

Quick actions:
  ./bin/plooma serve 8080          # built-in dev server
  ./bin/plooma migrate:status      # check pending migrations later

Next steps:
  - Edit .env to set APP_URL, SMTP credentials when needed
  - Drop a theme into ./theme/ (or use the plooma:theme-convert skill to build one
    from static HTML/PHP)
  - Edit robots.txt (at the project root) to point at your real sitemap URL
```

Only mention the cleanup line for files that were actually removed — if something didn't exist (e.g., user already deleted INSTALL.md before running), don't claim it was cleaned.

Adjust the login URL based on what the user said about deployment context. If they're installing for a production server (mentioned a domain), use that. If they didn't specify, default to `http://localhost/<install-folder>/admin/login` or just say "your domain + /admin/login".

## Edge cases & failure modes

- **Tarball download fails (network, 404, etc.)** → show the curl stderr verbatim, abort. Don't leave partial state. If the user passed `--version=` with a non-existent tag, suggest checking the available versions at `https://releases.plooma.io/versions.json`.
- **DB credentials wrong** → catch the FAIL output, re-ask credentials, regenerate `.env`, retry. Don't loop forever — give up after 3 tries and tell the user to debug DB connectivity manually.
- **User aborts mid-flow (Ctrl+C, says "stop")** → leave whatever's already on disk, tell them they can resume by running `./bin/plooma install` directly once `.env` is correct.
- **`.env` already exists** → never overwrite without explicit confirmation. Offer to merge new keys into existing file.
- **`bin/plooma` not executable** → `chmod +x bin/plooma` (the repo should ship it executable, but some systems strip the bit).
- **PHP not installed** → don't pre-check (per design), but if `./bin/plooma` errors with "command not found" or "PHP version", surface that error to the user with a hint about installing PHP 8.2+.

## Variants

The user might phrase the request in many ways. All of these should trigger and execute correctly:

- "Install plooma here"
- "Set up plooma-cms in this folder"
- "Bootstrap plooma"
- "Cria um projeto plooma novo"
- "Instala o plooma nessa pasta"
- "I want to use Plooma"
- "Clone and install plooma"

If the user passes a path (`/Users/me/projects/foo`), `cd` into it first, then run the flow. If the path doesn't exist, `mkdir -p` it first and ask for confirmation.

## What this skill does NOT do

- Theme creation/conversion → that's `plooma:theme-convert`
- Server provisioning, deployment automation → user manages their own host
- HTTPS / SSL setup → out of scope
- Backup/restore of existing installs → out of scope

Be honest about scope. If the user asks for any of the above mid-flow, complete the install first, then mention that the request is outside this skill.
