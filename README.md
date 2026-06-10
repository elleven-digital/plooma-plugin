# ellev — Claude Code plugin

Six skills covering the full lifecycle of a [Ellev](https://github.com/elleven-digital/ellev) project: install, upgrade, deploy via SSH, manage remote content, download a deployed site back to local, and convert static templates into Ellev themes.

Triggers in Portuguese and English.

## Installation

Clone into `~/.claude/skills/` so Claude Code picks up the skills:

```bash
cd ~/.claude/skills
git clone https://github.com/elleven-digital/ellev-plugin.git ellev
find ellev/skills -name "*.sh" -exec chmod +x {} \;
```

Restart your Claude Code session (or start a new one) and the skills will be available as `ellev:install`, `ellev:upgrade`, etc.

To update later: `cd ~/.claude/skills/ellev && git pull`.

## Skills included

| Skill | What it does |
|---|---|
| `ellev:install` | Fresh install of Ellev into the current directory. Downloads latest release tarball, gathers DB + admin credentials, writes `.env`, runs installer, records version in `.nano-version`. |
| `ellev:upgrade` | Upgrade an existing Ellev install. Reads `.nano-version`, fetches latest tag from GitHub, replaces only engine paths declared in `engine-manifest.json`, runs new migrations. Preserves `theme/`, `storage/`, `.env`, `.deploy/`, `.claude/`, etc. |
| `ellev:theme-convert` | Convert a folder of static HTML/PHP templates into a Ellev theme. Extracts shared header/footer, identifies editable fields, proposes a `site.json` schema, generates Ellev-compatible templates with `field()`/`option()`/`image_url()` wired in, seeds the admin panel with the original content. |
| `ellev:ssh-deploy` | Deploy to any host with SSH access (Hostinger, cPanel hosts, DigitalOcean, AWS, etc). Three actions: `init` (first-time deploy of files + DB + storage + theme), `update-cms` (push core + run migrations remotely), `update-theme` (push theme + run `schema:validate` and `page:sync` remotely). Saves config to `.deploy/ssh.json`. |
| `ellev:ssh-download` | Pull a deployed Ellev project back to local — files + DB + media. Inverse of `ssh-deploy`. Two modes: first-time (asks SSH + local DB credentials) and refresh (destructively mirrors remote into existing local install, backing up first). |
| `ellev:ssh-content` | Manage live content on a deployed Ellev site via SSH. Schema-aware via `bin/nano item:types`/`item:schema` — works on any Ellev site without hard-coding field names. Backs up tables before any write. |

## Typical workflow

```
ellev:install         ← create a fresh Ellev project locally
ellev:theme-convert   ← (optional) bring a static template in as the theme
ellev:ssh-deploy      ← init: first deploy to your server
ellev:ssh-content     ← create/edit posts, services, pages on prod
ellev:ssh-download    ← later: pull prod back to local to debug
ellev:upgrade         ← keep the engine current
ellev:ssh-deploy      ← update-cms: push the upgrade to prod
```

## Requirements

- **Local**: `php`, `mysql` client, `rsync`, `ssh`, `curl`, `jq`, `tar`
- **Remote (for `ssh-*` skills)**: SSH with key-based auth, MySQL/MariaDB, PHP ≥ 8.2
- **Hosts known to work**: Hostinger (port 65002), cPanel-based hosts (Locaweb, HostGator, KingHost, A2, SiteGround, Bluehost), DreamHost, VPS providers (DigitalOcean, Linode, Hetzner, Vultr), cloud VMs (AWS Lightsail/EC2, GCP, Azure). Anywhere with SSH + key auth + MySQL.
- **Hosts NOT supported**: PaaS without SSH (Vercel, Netlify, Heroku, Cloud Run, Cloudflare Pages)

## Structure

```
ellev-plugin/
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

The plugin version tracks Ellev releases: plugin `v1.x.y` is tested against Ellev `v1.x.y`. The skills are forward-compatible with patch releases of Ellev, but you may want to upgrade the plugin alongside major/minor releases of Ellev itself.

## Safety guarantees

- `ssh-deploy` refuses to overwrite an existing Ellev install (checks for `core/Bootstrap.php` at target before init).
- `ssh-content` backs up affected DB tables before any write.
- `ssh-download` backs up local state to `/tmp/ellev-download-backup-<timestamp>/` before destructive refresh.
- `upgrade` only touches files declared in `engine-manifest.json`. User content (`theme/`, `storage/`, `.env`, `.deploy/`, etc.) is never overwritten.
- All SSH config files (`.deploy/ssh.json`) are written with `chmod 0600` and ignored from git.

## Reporting issues

Open an issue at https://github.com/elleven-digital/ellev-plugin/issues — include the skill name, the command/intent that triggered it, and the relevant output (sanitized of credentials).

## License

MIT
