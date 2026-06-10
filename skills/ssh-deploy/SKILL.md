---
name: ssh-deploy
description: Deploy Ellev (formerly Nano CMS) to ANY host with SSH access via three actions — (1) `init` for first-time deploy of a complete Ellev project (files + database + storage + theme + robots.txt with the correct production URL); (2) `update-cms` for pushing core/Ellev changes and running pending DB migrations remotely; (3) `update-theme` for pushing theme-only changes and running schema:validate + page:sync remotely. Works on Hostinger, cPanel-based hosts (Locaweb, HostGator, KingHost, A2, SiteGround, Bluehost), DreamHost, VPS providers (DigitalOcean, Linode, Hetzner, Vultr), cloud VMs (AWS Lightsail/EC2, GCP, Azure) — anywhere with SSH + key auth + MySQL/MariaDB. ALWAYS inspects the target hosting path FIRST and refuses to overwrite an existing Ellev install — if `core/Bootstrap.php` is present at the target, only `update-cms` and `update-theme` are offered. On first run asks the user for SSH credentials, the absolute remote path where Ellev will live, the canonical site URL, and DB credentials, then saves them to `.deploy/ssh.json` (chmod 0600, gitignored) so subsequent deploys are fully automated. Use this skill whenever the user wants to push, deploy, ship, send, upload, or sincronizar their Ellev project to a remote server — phrases like "sobe esse projeto na hostinger", "deploy do nano", "publica na locaweb", "atualiza o tema em prod", "push do cms", "send to my VPS", "publish nano", "sobe pro DigitalOcean", "deploy nano via ssh". Triggers in Portuguese and English. Do NOT trigger for: deploys to PaaS without SSH (Vercel/Netlify/Heroku/Cloud Run), creating a Ellev install from scratch (that's ellev:install), converting templates to a Ellev theme (that's ellev:theme-convert), or local-only Ellev work (editing site.json, running migrations locally). The signal is "Ellev" + a deploy verb (deploy/sobe/atualiza/push/publish) targeting a server reachable by SSH.
---

# Deploy Ellev via SSH

Three actions: **init**, **update-cms**, **update-theme**. Each maps to a script in `scripts/`. Your job is to:

1. Detect what state the deploy is in (first time? config exists? Ellev already on remote?)
2. Pick the right action, or ask the user when it's ambiguous
3. Run the right script with the right config
4. Report the outcome

The skill is **host-agnostic**: works on Hostinger, cPanel-based shared hosts, DreamHost, VPS, cloud VMs — anywhere with SSH + key auth + MySQL/MariaDB. The only host-specific thing is the absolute remote path, which the user provides during first-time setup.

## Why these 3 actions and not more

A Ellev deploy has two "halves" that change at different cadences:

- **Schema/structure** lives in `theme/site.json` + `theme/templates/` + `theme/partials/` + assets. Editor changes this when the design or fields change. Touching it requires re-running `page:sync` so admin reflects new fields.
- **Engine** lives in `core/`, `bin/`, `migrations/`, plus root files (`index.php`, `.htaccess.example`, `robots.txt.example`). Changes when Ellev core is upgraded or new migrations land. Touching it requires running `migrate`. Ellev uses a flat layout — `index.php` is at the project root, not inside a `public/` subdir.

Real production data — items the editor created, form submissions, uploaded media — lives in the remote DB and `storage/uploads/`. Deploys must NEVER overwrite either, because that's the user's working state, not yours.

The 3 actions split along those lines:

| Action | What it touches remotely | Refuses if |
|---|---|---|
| `init` | Everything: files + DB import + storage + .env + robots.txt | Ellev already exists at target |
| `update-cms` | `core/`, `bin/`, `migrations/` + root engine files (`index.php`, `.htaccess.example`, `robots.txt.example`). Runs `migrate` after | Ellev does NOT exist at target |
| `update-theme` | `theme/` only (excluding `theme/install/`, `storage/uploads/`, `.env`). Runs `schema:validate` + `page:sync` after | Ellev does NOT exist at target |

`storage/uploads/`, `.env`, and the live DB are **never** overwritten after init.

## Phase 0 — Always inspect target first

Before doing anything, run `scripts/check-target.sh` against the configured target. It SSHes in, looks for `<remote_path>/core/Bootstrap.php`, prints `EXISTS` or `EMPTY`. The decision tree:

```
config exists? ── no ──▶ first-time setup (Phase 1)
                         then re-enter at Phase 2
       │
      yes
       │
       ▼
target state ── EMPTY ──▶ offer init (Phase 3)
                          (or update-* if user explicitly asks
                           and explains they expect Ellev elsewhere)
       │
      EXISTS
       │
       ▼
offer update-cms / update-theme. Refuse init.
Tell user clearly: "Ellev já existe em <path>.
init sobrescreveria o site em produção — bloqueado.
Posso rodar update-cms ou update-theme."
```

This existence check protects the user from a catastrophic re-init that would wipe their live DB and uploads. There is no `--force` for init. If they truly want to start over, they delete the remote dir manually first.

## Phase 1 — First-time setup (only when config doesn't exist)

The config lives at `.deploy/ssh.json` in the project root. If it's missing, gather everything in chat then save.

### Questions to ask, in order

Ask in one batch — most can be defaulted:

**SSH access** — pick ONE of:
- `ssh.alias` — a Host alias from the user's `~/.ssh/config` (cleanest). If this is set, use it; ignore the other ssh.* fields.
- OR `ssh.host` + `ssh.port` (default `22` — Hostinger uses `65002`, some hosts use other custom ports) + `ssh.user` + `ssh.key_path` (default `~/.ssh/id_ed25519`).

If the user doesn't know whether SSH is available, point them to their host's panel (cPanel → SSH Access, hPanel → Advanced → SSH Access, etc.). Most shared plans Premium and up support SSH; basic plans usually don't. VPS/cloud always do.

**Remote path** — `ssh.remote_path` is the absolute path on the server where Ellev will live. This is THE most important field, and it varies by host:

| Host type | Typical `ssh.remote_path` |
|---|---|
| Hostinger shared | `/home/uXXXX/domains/<domain>/public_html` |
| cPanel shared (HostGator, A2, SiteGround, Bluehost) | `/home/<user>/public_html` (root domain) or `/home/<user>/public_html/<subdir>` |
| Locaweb | `/home/<user>/public_html` |
| KingHost | `/home/<user>/www` |
| DreamHost | `/home/<user>/<domain>` |
| VPS (DigitalOcean, Linode, Hetzner, Vultr) | wherever Apache/Nginx serves — typically `/var/www/<project>` or `/srv/<domain>` |
| AWS Lightsail / EC2 | usually `/var/www/html` or `/opt/bitnami/apache2/htdocs` |

If the user doesn't know, ask them to SSH in and run `pwd` from their web root directory. Or check their host's panel for "Document Root" / "DocumentRoot" path.

**Site URL and subpath** — what users will see in the browser:
- `site.url` — final canonical URL with scheme (used in `APP_URL`, sitemap, robots.txt). Examples: `https://expmark.com.br`, `https://example.com/blog`.
- `site.subpath` — only set if the site lives under a subpath, e.g. `/blog`. **This affects Ellev's `APP_BASE_PATH` env var** — the skill writes it to `.env` automatically. Empty string means root domain.

The subpath and `remote_path` are independent: a site at `https://example.com/blog/` might live at `/var/www/blog/` (no `blog` in the path) or at `/home/user/public_html/blog/` (subpath in the path). Don't try to derive one from the other.

**Database** (must be already created on the remote — Ellev can't create databases, the user does it via host panel or `mysql` CLI):
- `db.name`, `db.user`, `db.password` — exactly as the host panel created them. Some hosts prefix names/users (Hostinger: `u12345678_expmark` / `u12345678_admin`). cPanel similar. VPS: whatever the user created.
- `db.host` defaults to `localhost` (same machine as SSH). Override if the host has a separate DB server.

**Local DB** (where the project's current data lives — used to dump on init):
- Default to reading the project's `.env` for `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`. If not present, ask.

After gathering, write `.deploy/ssh.json` (see schema below), `chmod 0600`, append `.deploy/` to `.gitignore` if missing.

### Config schema

Minimum (with SSH alias):
```json
{
  "ssh": {
    "alias": "my-server",
    "remote_path": "/var/www/expmark"
  },
  "site": {
    "url": "https://expmark.com.br",
    "subpath": ""
  },
  "db": {
    "host": "localhost",
    "name": "expmark_prod",
    "user": "expmark_app",
    "password": "***"
  },
  "local": {
    "db_host": "localhost",
    "db_name": "expmark",
    "db_user": "root",
    "db_password": "Root#123"
  }
}
```

Without alias (direct SSH):
```json
{
  "ssh": {
    "host": "server.example.com",
    "port": 22,
    "user": "deployer",
    "key_path": "~/.ssh/id_ed25519",
    "remote_path": "/var/www/expmark"
  },
  ...
}
```

The scripts handle both shapes. If you set `ssh.alias`, the skill ignores the direct fields.

### Validation before saving

After gathering but before saving the config, the skill validates:

- SSH connects (`scripts/check-target.sh` returns successfully without auth error)
- DB connects (run `mysql -e 'SELECT 1'` over SSH)
- `<remote_path>` directory exists or can be created
- `site.url` is parseable and uses `https://` (warn on `http://`)

If any check fails, surface the error clearly, let the user fix and retry. Don't save a broken config.

## Phase 2 — User picks an action (or you infer it)

Match user phrasing:

| User says | Action |
|---|---|
| "primeiro deploy", "subir pela primeira vez", "deploy inicial", "publicar a primeira vez" | `init` (only if target is EMPTY) |
| "atualiza o cms", "push do core", "rodar migrations em prod", "sobe atualização do nano" | `update-cms` |
| "atualiza o tema", "push do template", "subir mudanças do design", "atualização do site.json" | `update-theme` |
| "deploy" (sem qualificar) + target EMPTY | confirm → `init` |
| "deploy" (sem qualificar) + target EXISTS | ask: "Mudou theme ou core? (theme/cms/ambos)". Run one or both. |

When in doubt, ask. Better to confirm than to overwrite the wrong thing.

## Phase 3 — Execute

### `init` — first-time deploy

Run `scripts/init.sh --config .deploy/ssh.json`. It:

1. Re-checks target is empty (refuses if Ellev exists)
2. Dumps local DB to `/tmp/nano-init-<timestamp>.sql`
3. `rsync -avz --delete-after` of project files to remote, **excluding**:
   - `.env`, `.git/`, `.deploy/`, `node_modules/`
   - `storage/cache/*`, `storage/logs/*`
   - `theme/` legacy source files (anything matching `theme/*.php` directly in theme root, not in `theme/templates/` etc — these are leftovers from `ellev:theme-convert`)
4. Generates remote `.env` from config (`APP_URL`, `APP_BASE_PATH`, `DB_*`, etc.) — **not committing** anything from local `.env`
5. Uploads SQL dump and runs `mysql < dump.sql` on remote → cleans up the dump
6. Runs on remote: `php bin/ellev migrate` (just in case the dump didn't include the migration log table state)
7. Writes `robots.txt` on remote with `Sitemap: <APP_URL>/sitemap.xml` and a default `User-agent: * / Allow: /` (overrides the example.com placeholder shipped in the repo)
8. `chmod 0640 .env` on remote (so web server can read but world cannot)
9. Verifies with `curl -s -o /dev/null -w "%{http_code}" <APP_URL>` — expects 200, fails loud if 50x or 404

Print final URL + admin login URL on success.

### `update-cms` — push core changes only

Run `scripts/update-cms.sh --config .deploy/ssh.json`. It:

1. Verifies Ellev exists at target (refuses if EMPTY)
2. `rsync -avz` (with per-subtree `--delete`) of `core/`, `bin/`, `migrations/` + Ellev-shipped root files (`index.php`, `.htaccess.example`, `robots.txt.example`) — **not** theme, storage, .env, live `.htaccess`, live `robots.txt`
3. Runs on remote: `php bin/ellev migrate` to apply any pending migrations from the new files
4. Verifies the homepage still returns 200

Doesn't touch `theme/`, `storage/uploads/`, or `.env`. The live DB schema gets updated by `migrate`.

### `update-theme` — push theme changes only

Run `scripts/update-theme.sh --config .deploy/ssh.json`. It:

1. Verifies Ellev exists at target (refuses if EMPTY)
2. `rsync -avz` (no `--delete`) of `theme/` only, with **excludes**:
   - `theme/install/seed.php` (already ran on init — re-running would be guarded by idempotency but no need to ship it)
   - `storage/uploads/*` (lives outside theme but worth listing for clarity)
   - `.env`
3. Runs on remote: `php bin/ellev schema:validate && php bin/ellev page:sync`

`page:sync` adds new pages declared in `site.json` to the DB (status: draft) and updates existing page metadata. It does NOT delete or alter content the editor already typed in admin — it only touches structural metadata.

## Output to user

For every action, end with a clean summary the user can act on:

```
✓ <action> completo

Site:    https://expmark.com.br
Admin:   https://expmark.com.br/admin/login
Config:  .deploy/ssh.json (chmod 0600)

Resumo:
  - 47 arquivos sincronizados (rsync)
  - 2 migrations aplicadas: 2026_05_01_users_field, 2026_05_03_form_fields
  - page:sync: 0 added, 3 updated
  - HTTP 200 verificado em /
```

If something failed, show the failing step and what the user should check. Don't keep going on a broken foundation.

## Safety guarantees

The skill never:

- Runs `init` against an existing Ellev install
- Uses `--delete` on rsync targets that contain `storage/uploads/` (after init)
- Writes anything to remote `.env` except during init
- Overwrites the live remote DB (only init imports the dump, and only after target-empty check)
- Pushes the project's local `.env` (it would leak local DB credentials)
- Asks for credentials a second time when the config exists

If any guarantee can't be honored, abort and tell the user explicitly.

## Common host gotchas

Things that can break on first SSH connection — be ready to diagnose:

- **PHP not in PATH**: Some hosts (cPanel) require explicit version like `/opt/cpanel/ea-php82/root/usr/bin/php`. Test with `ssh <alias> "php -v"` during preflight. If it fails, ask user to add a `~/.bashrc` alias or use a wrapper.
- **MySQL on different host**: rare on shared, common on cloud. If `db.host: localhost` fails, try the panel-provided host (e.g., AWS RDS endpoint).
- **rsync blocked**: very rare but exists on locked-down jail shells. Symptom: `rsync: Failed to exec ssh`. Fallback: tar over ssh + extract remotely.
- **SSH password-only**: this skill requires key auth (`BatchMode=yes`). User runs `ssh-copy-id <user@host>` to set up.
- **Custom ports**: Hostinger uses 65002. Most others 22. Ask if unsure or check the host panel.

When preflight fails, the error message tells the user which check failed; that's enough to diagnose.

## Scripts directory

The actual deploy logic lives in `scripts/`. Each script:

- Takes `--config <path>` pointing to the JSON
- Reads config via `jq`
- Resolves SSH command (alias OR direct host/port/user/key)
- Prints progress to stderr; final status to stdout
- Exits non-zero on any failure

| Script | Purpose |
|---|---|
| `check-target.sh` | SSH + check if `<remote_path>/core/Bootstrap.php` exists. Prints `EXISTS` or `EMPTY`. Use before any other script. |
| `preflight.sh` | Full check: SSH connectivity + DB connectivity + target state. Use during first-time setup validation. |
| `init.sh` | Full init deploy. Refuses if target has Ellev. |
| `update-cms.sh` | core/, bin/, migrations/ rsync + root engine files + `migrate`. Refuses if target empty. |
| `update-theme.sh` | Theme rsync + `schema:validate` + `page:sync`. Refuses if target empty. |

Read the scripts to understand exactly what they do before invoking. They're the source of truth for the actual deploy operations.

## Don't surprise the user

Never:

- Skip the target inspection (Phase 0). Even if the user is sure Ellev isn't there, check. The cost is one SSH command; the benefit is preventing a wipe.
- Run multiple actions in parallel against the same target — they're not safe to interleave.
- Modify `.deploy/ssh.json` without explicit consent. If a credential is wrong, ask the user; don't silently update.
- Push beyond what the user asked. If they say "atualiza o tema", do `update-theme` and stop. Don't also run `update-cms`.
- Treat empty feedback as "everything fine" — re-check the verification step (HTTP 200, migrations applied count) before claiming success.
- Guess `ssh.remote_path` from `site.url` or `site.domain`. The on-disk path varies by host; the URL doesn't tell you. Always ask the user explicitly.

If a deploy fails midway (network drop, SSH timeout, partial rsync), the next run is safe — rsync resumes, `migrate` is idempotent, `page:sync` is idempotent, robots.txt overwrite is idempotent. The only non-idempotent step is the SQL import in `init`, which is guarded by the target-empty precondition. So as long as Phase 0 is honored, retrying is always safe.
