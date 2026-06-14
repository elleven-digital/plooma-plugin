# plooma — Claude Code plugin

Six skills covering the full lifecycle of a [Plooma](https://github.com/elleven-digital/plooma) project: install, upgrade, deploy via SSH, manage remote content, download a deployed site back to local, and convert static templates into Plooma themes.

Triggers in Portuguese and English.

## Installation

Clone into `~/.claude/skills/` so Claude Code picks up the skills:

```bash
cd ~/.claude/skills
git clone https://github.com/elleven-digital/plooma-plugin.git plooma
find plooma/skills -name "*.sh" -exec chmod +x {} \;
```

Restart your Claude Code session (or start a new one) and the skills will be available as `plooma:install`, `plooma:upgrade`, etc.

To update later: `cd ~/.claude/skills/plooma && git pull`.

## Skills included

| Skill | What it does |
|---|---|
| `plooma:install` | Fresh install of Plooma into the current directory. Downloads latest release tarball, gathers DB + admin credentials, writes `.env`, runs installer, records version in `.plooma-version`. |
| `plooma:upgrade` | Upgrade an existing Plooma install. Reads `.plooma-version`, fetches latest tag from GitHub, replaces only engine paths declared in `engine-manifest.json`, runs new migrations. Preserves `theme/`, `storage/`, `.env`, `.deploy/`, `.claude/`, etc. |
| `plooma:theme-convert` | Convert a folder of static HTML/PHP templates into a Plooma theme. Extracts shared header/footer, identifies editable fields, proposes a `site.json` schema, generates Plooma-compatible templates with `field()`/`option()`/`image_url()` wired in, seeds the admin panel with the original content. |
| `plooma:ssh-deploy` | Deploy to any host with SSH access (Hostinger, cPanel hosts, DigitalOcean, AWS, etc). Three actions: `init` (first-time deploy of files + DB + storage + theme), `update-cms` (push core + run migrations remotely), `update-theme` (push theme + run `schema:validate` and `page:sync` remotely). Saves config to `.deploy/ssh.json`. |
| `plooma:ssh-download` | Pull a deployed Plooma project back to local — files + DB + media. Inverse of `ssh-deploy`. Two modes: first-time (asks SSH + local DB credentials) and refresh (destructively mirrors remote into existing local install, backing up first). |
| `plooma:ssh-content` | Manage live content on a deployed Plooma site via SSH. Schema-aware via `bin/plooma item:types`/`item:schema` — works on any Plooma site without hard-coding field names. Backs up tables before any write. |

## Typical workflow

```
plooma:install         ← create a fresh Plooma project locally
plooma:theme-convert   ← (optional) bring a static template in as the theme
plooma:ssh-deploy      ← init: first deploy to your server
plooma:ssh-content     ← create/edit posts, services, pages on prod
plooma:ssh-download    ← later: pull prod back to local to debug
plooma:upgrade         ← keep the engine current
plooma:ssh-deploy      ← update-cms: push the upgrade to prod
```

## Requirements

- **Local**: `php`, `mysql` client, `rsync`, `ssh`, `curl`, `jq`, `tar`
- **Remote (for `ssh-*` skills)**: SSH with key-based auth, MySQL/MariaDB, PHP ≥ 8.2
- **Hosts known to work**: Hostinger (port 65002), cPanel-based hosts (Locaweb, HostGator, KingHost, A2, SiteGround, Bluehost), DreamHost, VPS providers (DigitalOcean, Linode, Hetzner, Vultr), cloud VMs (AWS Lightsail/EC2, GCP, Azure). Anywhere with SSH + key auth + MySQL.
- **Hosts NOT supported**: PaaS without SSH (Vercel, Netlify, Heroku, Cloud Run, Cloudflare Pages)

## Structure

```
plooma-plugin/
├── .claude-plugin/
│   └── plugin.json
├── README.md
├── shared/
│   └── ssh-lib.sh          ← SSH/rsync/MySQL helpers used by all ssh-* skills
└── skills/
    ├── install/
    ├── upgrade/
    ├── theme-convert/
    ├── ssh-deploy/         ← scripts/_lib.sh is a thin shim that sources shared/
    ├── ssh-download/       ← scripts/_lib.sh is a thin shim that sources shared/
    └── ssh-content/        ← scripts/_lib.sh is a thin shim that sources shared/
```

Each skill has its own `SKILL.md` (the instructions Claude reads) and, where applicable, a `scripts/` folder with the bash helpers it runs.

The three `ssh-*` skills all read the same `.deploy/ssh.json` and share SSH command building, rsync/scp targeting, DB credentials parsing, and remote-path resolution. Those helpers live in `shared/ssh-lib.sh`. Each skill's `scripts/_lib.sh` is a short shim that sources the shared lib and defines a skill-specific `parse_args()` (since each skill accepts a different set of flags). A bug fix or feature in the shared layer benefits all three skills at once.

## Versioning

The plugin version tracks Plooma releases: plugin `v1.x.y` is tested against Plooma `v1.x.y`. The skills are forward-compatible with patch releases of Plooma, but you may want to upgrade the plugin alongside major/minor releases of Plooma itself.

## Safety guarantees

- `ssh-deploy` refuses to overwrite an existing Plooma install (checks for `core/Bootstrap.php` at target before init).
- `ssh-content` backs up affected DB tables before any write.
- `ssh-download` backs up local state to `/tmp/plooma-download-backup-<timestamp>/` before destructive refresh.
- `upgrade` only touches files declared in `engine-manifest.json`. User content (`theme/`, `storage/`, `.env`, `.deploy/`, etc.) is never overwritten.
- All SSH config files (`.deploy/ssh.json`) are written with `chmod 0600` and ignored from git.

## Reporting issues

Open an issue at https://github.com/elleven-digital/plooma-plugin/issues — include the skill name, the command/intent that triggered it, and the relevant output (sanitized of credentials).

## License

MIT
