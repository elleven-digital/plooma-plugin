---
name: ssh-download
description: Pull a deployed Ellev (formerly Nano CMS) project from a remote server down to the current local folder — files + database + media uploads — for local debugging, dev parity, or moving a site to a new machine. Inverse of ellev:ssh-deploy. Two modes detected automatically: (A) **first-time** when current folder is empty, asks SSH + remote path + local DB credentials, downloads, configures `.env` for localhost, saves config to `.deploy/ssh.json`; (B) **refresh** when the current folder already has a Ellev install with `.deploy/ssh.json`, reuses everything, then DESTRUCTIVELY replaces the local copy with an exact mirror of the remote (drops + recreates local DB, deletes ALL local files including `theme/`, `storage/`, `.git/`, the live `.env` and `.htaccess`), bringing back only environment variables adjusted to the local context. Always backs up the local state to `/tmp/ellev-download-backup-<timestamp>/` before any destructive operation, so the user has a recovery window. Use this skill whenever the user wants to bring production down to local — phrases like "baixa o nano da hostinger", "pull do servidor pro meu pc", "baixa o site de produção", "clona o nano que tá no servidor pra cá", "preciso debugar local com os dados de produção", "sync from server to local", "mirror prod locally", "download my nano site from VPS". Triggers in Portuguese and English. Do NOT use for: (a) deploying TO a server (that's ellev:ssh-deploy), (b) installing fresh Ellev with no remote source (that's ellev:install), (c) downloading just the database (user can run `mysqldump` over SSH directly for that), (d) syncing only files without the DB (this skill is all-or-nothing — full mirror).
---

# Pull Ellev from a remote server to local

This skill is the inverse of `ellev:ssh-deploy`. It connects to a remote Ellev install via SSH, pulls down the entire project (files + DB dump + uploads), and reconstitutes it locally. The local result is byte-for-byte identical to remote, except the environment variables (DB credentials, APP_URL, SMTP) are rewritten to match the local context.

## Why this exists

A real Ellev workflow has two ends — production on a server, and dev on the user's laptop. `ellev:ssh-deploy` handles local→remote. Sometimes the data flow needs to reverse:

- Editor created content directly in the production admin and dev needs that content locally to debug
- Site is moving from one host to another and dev needs a working copy to migrate from
- Dev machine got wiped/replaced and needs to clone production to start working again
- Recovery from a corrupted local copy: just nuke local and pull production exactly

For each of these, the operation is the same: replace local with remote, adjusting only what HAS to change between environments (the env vars).

## Two modes, decided by current folder state

```
.deploy/ssh.json exists in cwd? ──no──▶ Mode A: first-time download
                                        Ask config, save it, download.
       │
      yes
       │
       ▼
core/Bootstrap.php exists?  ──no──▶ Mode A: first-time (config existed but no Ellev —
                                            unusual, but treat as fresh)
       │
      yes
       │
       ▼
                                     Mode B: refresh
                                     Reuse config, WIPE local, mirror remote.
```

**Mode A (first-time)**: gather everything from the user, validate, save config, download. Creates a working Ellev install in the current folder.

**Mode B (refresh)**: load saved config, validate, **destroy local state** (with backup), download from remote.

In both modes the result is the same: the local folder contains an exact replica of the remote project, with `.env` adjusted for local development.

## Phase 0 — Detect mode

1. Read `.deploy/ssh.json` if it exists. Treat existence as evidence of established mode.
2. Check `core/Bootstrap.php`. If config exists but Bootstrap doesn't, the project was previously initialized but later wiped — fall back to Mode A using the config as defaults.
3. If folder is non-empty but has no `.deploy/ssh.json` and no `core/Bootstrap.php`, this is ambiguous — STOP and ask the user: "Não detectei nem Ellev nem `.deploy/ssh.json`, mas a pasta tem arquivos. Quer (a) abortar, (b) tratar como nova instalação (vou backupear esses arquivos antes de baixar)?"

## Phase 1 — Gather config (Mode A only)

If `.deploy/ssh.json` doesn't exist, ask everything in one batch (most are defaultable):

**SSH access** — pick ONE of:
- `ssh.alias` — Host alias from `~/.ssh/config` (cleanest)
- OR `ssh.host` + `ssh.port` (default `22`; Hostinger is `65002`) + `ssh.user` + `ssh.key_path` (default `~/.ssh/id_ed25519`)

**Remote path** — `ssh.remote_path` is the absolute path on the server where Ellev lives. Same hosts table as ellev:ssh-deploy:
- Hostinger shared: `/home/uXXXX/domains/<domain>/public_html`
- cPanel: `/home/<user>/public_html` (root domain) or with subdir
- VPS: `/var/www/<project>` typically

If the user doesn't know, ask them to SSH in and run `pwd` from the web root.

**Remote database** (the production DB):
- `db.name`, `db.user`, `db.password` — exactly as the host panel created them
- `db.host` defaults to `localhost`

**Local database** (where to import the dump locally):
- `local.db_host` (default `localhost`)
- `local.db_name` — suggest the same as remote name OR a `<remote-name>_local` variant. Ask.
- `local.db_user`, `local.db_password` — local MySQL/MariaDB credentials. Often `root` / blank for dev.

**Local site URL** (used to write `APP_URL` in the local `.env`):
- `site.local_url` — what URL the user accesses locally. Examples: `http://localhost/expmark`, `http://localhost:8080`, `http://expmark.test`.
- `site.local_subpath` — typically `/` (or `/<folder>` if served from a subdir of the dev server)

After gathering, save to `.deploy/ssh.json`, `chmod 0600`. Same schema as `ellev:ssh-deploy` — this skill and that one share the config file.

### Config schema (extends ssh-deploy schema)

```json
{
  "ssh": {
    "alias": "my-server",
    "remote_path": "/var/www/expmark"
  },
  "site": {
    "url": "https://expmark.com.br",
    "subpath": "",
    "local_url": "http://localhost/expmark",
    "local_subpath": ""
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
    "db_password": ""
  }
}
```

The `local.*` fields are required for download (they'd be optional for ssh-deploy).

## Phase 2 — Preflight

Run `scripts/preflight.sh --config .deploy/ssh.json`. It checks, in order:

1. **SSH connects** — `ssh <opts> 'echo ok'`. Fails with auth/network error → tell user to verify credentials/network.
2. **Remote has Ellev** — `ssh <opts> "test -f <remote_path>/core/Bootstrap.php && echo HAS_NANO || echo NO_NANO"`. If NO_NANO, abort with: "Não encontrei Ellev em `<remote_path>` no servidor. O caminho está correto?"
3. **Remote DB connects** — `ssh <opts> "mysql -u<user> -p<pass> -e 'SELECT 1' <name>"`. Catches typos in DB credentials.
4. **Local DB connects** — `mysql -u<local-user> -p<local-pass> -e 'SELECT 1'`. If wrong credentials, abort and ask user to fix.
5. **Local DB user has DROP/CREATE privileges** — try `mysql -e "CREATE DATABASE IF NOT EXISTS __ellev_priv_check; DROP DATABASE __ellev_priv_check"`. If permission denied, abort.

If any check fails, surface the error verbatim. Don't save a broken config; don't proceed.

## Phase 3 — Confirm with the user

Show the plan in plain terms. Be VERY explicit about what gets destroyed in Mode B:

**Mode A (empty folder):**
```
Download plan (first-time):

  Source:
    SSH:        <user@host:port> → <remote_path>
    Remote DB:  <db.name> @ <db.host> (mysqldump over SSH)

  Destination (this folder):
    Local DB:   <local.db_name> @ <local.db_host>
                  → CREATE if missing, otherwise dump-and-import

  Will:
    1. Pull remote files via rsync into current folder
    2. Dump remote DB and import into local DB
    3. Generate local .env (APP_URL, DB_*, etc.)
    4. Save .deploy/ssh.json

Continue? (y/N)
```

**Mode B (existing Ellev):**
```
⚠️  Refresh plan (DESTRUCTIVE):

  This folder currently has a Ellev install. Refreshing will:
    • Backup local files → /tmp/ellev-download-backup-<ts>/files/
    • Backup local DB → /tmp/ellev-download-backup-<ts>/local-db.sql
    • DELETE everything in current folder (including theme/, storage/,
      .git/, .env, .htaccess, robots.txt — every file and hidden file)
    • DROP local DB and recreate empty
    • Pull all files from <remote> via rsync
    • Import remote DB dump into freshly recreated local DB
    • Write fresh .env with local values

  Backup will live at /tmp/... — delete after you verify the new state works.
  No automatic rollback — if you need the old state back, restore from /tmp manually.

  Source:
    SSH:        <ssh-info>
    Remote DB:  <remote-db-info>
    Remote path: <path>

Type "REFRESH" (uppercase) to continue, or anything else to abort.
```

Mode B uses an uppercase confirmation phrase (not just `y`) because the destruction scope is large. Make sure the user really means it.

## Phase 4 — Execute

Run `scripts/download.sh --config .deploy/ssh.json --mode <A|B>`. The script:

1. **Backup (Mode B only)**: 
   - `mkdir -p /tmp/ellev-download-backup-<ts>/files`
   - Move all current dir contents (visible + hidden) into the backup dir, EXCEPT `.deploy/` (we read that into memory before this step so it doesn't matter, but moving it would lose the config mid-script)
   - Dump local DB to `/tmp/ellev-download-backup-<ts>/local-db.sql`

2. **Wipe local (Mode B only)**:
   - At this point everything is in backup. The current dir is effectively empty.
   - Drop and recreate the local DB

3. **Download files**:
   - `rsync -avz --delete <remote>:<remote_path>/ ./` — exact mirror of remote
   - No excludes. The remote is the source of truth.
   - This brings down `theme/`, `storage/uploads/`, `core/`, everything

4. **Download DB**:
   - `ssh <remote> "mysqldump --single-transaction --no-tablespaces -u<user> -p<pass> <name>" > /tmp/remote-dump-<ts>.sql`
   - The `--single-transaction` keeps it consistent without locking; `--no-tablespaces` works around Hostinger/cPanel restrictions
   - Local DB is empty at this point (Mode A: just created; Mode B: just dropped+recreated). Import:
   - `mysql -u<local-user> -p<local-pass> <local-name> < /tmp/remote-dump-<ts>.sql`
   - Delete the dump file after import

5. **Generate local .env**:
   - Start from the downloaded `.env.example` (which came down via rsync)
   - Write actual values:
     - `APP_URL=<site.local_url>`
     - `APP_BASE_PATH=<site.local_subpath if not "/", else empty>`
     - `DB_HOST=<local.db_host>`
     - `DB_DATABASE=<local.db_name>`
     - `DB_USERNAME=<local.db_user>`
     - `DB_PASSWORD=<local.db_password>`
     - SMTP_*: leave blank (no spam from dev)
     - INITIAL_USER_*: leave blank (already set up)
   - `chmod 0600 .env`

6. **Permissions**:
   - `chmod -R 0775 storage/` (so local web server can write)

7. **Save/refresh .deploy/ssh.json**:
   - Mode A: write fresh config
   - Mode B: was already in memory, restore it (deleted along with everything else in the wipe)

## Phase 5 — Verify

After download:

1. Run `php bin/ellev migrate:status` from current dir. Should report "All migrations are up to date" (the dump included the migrations table state).
2. Optional: print the path to `.env` and remind user to test with `./bin/ellev serve 8080` or their local web server.

## Phase 6 — Report

```
✓ Download complete

Source:      <remote SSH info>
Local path:  <pwd>
Local DB:    <local.db_name> @ <local.db_host>

Mirrored:
  - <N> files downloaded via rsync
  - <SQL dump size> imported into <local.db_name>
  - .env regenerated for local development

Backup (Mode B):
  /tmp/ellev-download-backup-<ts>/
    ├── files/             # everything that was in this folder before
    └── local-db.sql       # local DB dump before drop

Test it:
  ./bin/ellev serve 8080
  # or use your local web server (Apache/Nginx) pointed at this folder

Login at <local_url>/admin/login with the same credentials as production.
```

For Mode B, mention the backup path explicitly so the user knows where to recover if something's off.

## Safety guarantees

The skill never:
- Skips the preflight (Phase 2). Even on a repeat run.
- Wipes local without backing up first.
- Wipes local DB without dumping first.
- Touches the remote (this is download, not push — purely read-only on remote).
- Uses `--delete` on rsync without verifying remote has Ellev (preflight covers this).
- Saves a `.deploy/ssh.json` that didn't pass validation.
- Asks for credentials when config exists (always reuse).

If any guarantee can't be honored, abort with a clear error and leave local state untouched (or restored from backup).

## Edge cases

- **Local has user's WIP changes** (Mode B): they get backed up to `/tmp/...` before the wipe. Surfaced in the report. User must manually merge after if they want.
- **Local DB user is `root` with no password**: works on most local dev setups (MySQL on macOS via Homebrew, MAMP, XAMPP). Validated by preflight.
- **Remote MySQL refuses `mysqldump` because of `--lock-tables`**: `--single-transaction` plus `--no-tablespaces` already covers most shared host restrictions. If still fails, tell user to ask hostinger/cPanel support to enable mysqldump access.
- **Network interruption mid-rsync**: rsync is resumable — re-running picks up where it left off. The DB dump is independent — re-running redumps. Safe to retry from start.
- **Remote storage/uploads is huge** (>1GB): warn user before download, offer `--exclude=storage/uploads/` flag. (Default behavior: include everything.)
- **Backup fills up /tmp**: warn after backup if size is over 500MB, offer alternative location.

## Common host gotchas

- **mysqldump not in PATH on remote**: shared hosts often need full path like `/usr/bin/mysqldump`. Test in preflight; fall back to common paths if `mysqldump` alone fails.
- **PHP not in PATH**: needed for the `php bin/ellev migrate:status` verify step. Less critical here than in deploy. If not found, skip verification with a warning.
- **rsync excluded from jail shell**: rare, but if `rsync` fails to exec, fallback is `tar | ssh | tar -x` (much slower, no resume). Document but don't auto-fallback in v1.

## Scripts

The actual operations live in `scripts/`. Each script:
- Takes `--config <path>` pointing to the JSON
- Reads config via `jq`
- Resolves SSH command (alias OR direct host/port/user/key)
- Prints progress to stderr; final status to stdout
- Exits non-zero on any failure

| Script | Purpose |
|---|---|
| `_lib.sh` | Shared helpers: `resolve_ssh_cmd`, `read_config`, `confirm_yes` |
| `preflight.sh` | All 5 preflight checks (SSH + remote Ellev + remote DB + local DB + local DB privs) |
| `download.sh` | Main operation: backup → wipe → rsync → dump+import → write .env → save config |

Read the scripts to understand the exact commands before invoking. They're the source of truth for the actual destructive operations.

## What this skill does NOT do

- Deploy TO a server (use `ellev:ssh-deploy`)
- Install Ellev without a remote source (use `ellev:install`)
- Sync only DB without files, or files without DB — this skill is all-or-nothing
- Restore from a backup made by an earlier run (manual operation; backups are at `/tmp/`)
- Re-establish git history. The downloaded copy comes via rsync, so there's no `.git/` (unless remote happened to have one, which it won't if it was deployed via ssh-deploy). To get a git-tracked Ellev for `ellev:upgrade` later, the user can `git clone` upstream into a temp dir and copy `.git/` over. Out of scope for v1.
