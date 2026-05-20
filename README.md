# nano-cms — Claude Code plugin

Six skills covering the full lifecycle of a [Nano CMS](https://github.com/rickfalaschi/nano-cms) project: install, upgrade, deploy via SSH, manage remote content, download a deployed site back to local, and convert static templates into Nano themes.

Triggers in Portuguese and English.

## Installation

Clone into `~/.claude/skills/` so Claude Code picks up the skills:

```bash
cd ~/.claude/skills
git clone https://github.com/rickfalaschi/nano-cms-plugin.git nano-cms
find nano-cms/skills -name "*.sh" -exec chmod +x {} \;
```

Restart your Claude Code session (or start a new one) and the skills will be available as `nano-cms:install`, `nano-cms:upgrade`, etc.

To update later: `cd ~/.claude/skills/nano-cms && git pull`.

## Skills included

| Skill | What it does |
|---|---|
| `nano-cms:install` | Fresh install of Nano CMS into the current directory. Downloads latest release tarball, gathers DB + admin credentials, writes `.env`, runs installer, records version in `.nano-version`. |
| `nano-cms:upgrade` | Upgrade an existing Nano install. Reads `.nano-version`, fetches latest tag from GitHub, replaces only engine paths declared in `engine-manifest.json`, runs new migrations. Preserves `theme/`, `storage/`, `.env`, `.deploy/`, `.claude/`, etc. |
| `nano-cms:theme-convert` | Convert a folder of static HTML/PHP templates into a Nano theme. Extracts shared header/footer, identifies editable fields, proposes a `site.json` schema, generates Nano-compatible templates with `field()`/`option()`/`image_url()` wired in, seeds the admin panel with the original content. |
| `nano-cms:ssh-deploy` | Deploy to any host with SSH access (Hostinger, cPanel hosts, DigitalOcean, AWS, etc). Three actions: `init` (first-time deploy of files + DB + storage + theme), `update-cms` (push core + run migrations remotely), `update-theme` (push theme + run `schema:validate` and `page:sync` remotely). Saves config to `.deploy/ssh.json`. |
| `nano-cms:ssh-download` | Pull a deployed Nano project back to local — files + DB + media. Inverse of `ssh-deploy`. Two modes: first-time (asks SSH + local DB credentials) and refresh (destructively mirrors remote into existing local install, backing up first). |
| `nano-cms:ssh-content` | Manage live content on a deployed Nano site via SSH. Schema-aware via `bin/nano item:types`/`item:schema` — works on any Nano site without hard-coding field names. Backs up tables before any write. |

## Typical workflow

```
nano-cms:install         ← create a fresh Nano project locally
nano-cms:theme-convert   ← (optional) bring a static template in as the theme
nano-cms:ssh-deploy      ← init: first deploy to your server
nano-cms:ssh-content     ← create/edit posts, services, pages on prod
nano-cms:ssh-download    ← later: pull prod back to local to debug
nano-cms:upgrade         ← keep the engine current
nano-cms:ssh-deploy      ← update-cms: push the upgrade to prod
```

## Requirements

- **Local**: `php`, `mysql` client, `rsync`, `ssh`, `curl`, `jq`, `tar`
- **Remote (for `ssh-*` skills)**: SSH with key-based auth, MySQL/MariaDB, PHP ≥ 8.2
- **Hosts known to work**: Hostinger (port 65002), cPanel-based hosts (Locaweb, HostGator, KingHost, A2, SiteGround, Bluehost), DreamHost, VPS providers (DigitalOcean, Linode, Hetzner, Vultr), cloud VMs (AWS Lightsail/EC2, GCP, Azure). Anywhere with SSH + key auth + MySQL.
- **Hosts NOT supported**: PaaS without SSH (Vercel, Netlify, Heroku, Cloud Run, Cloudflare Pages)

## Structure

```
nano-cms-plugin/
├── .claude-plugin/
│   └── plugin.json
├── README.md
└── skills/
    ├── install/
    ├── upgrade/
    ├── theme-convert/
    ├── ssh-deploy/
    ├── ssh-download/
    └── ssh-content/
```

Each skill has its own `SKILL.md` (the instructions Claude reads) and, where applicable, a `scripts/` folder with the bash helpers it runs. The shared SSH/rsync/MySQL helpers currently live duplicated inside each `ssh-*` skill's `scripts/_lib.sh` — a future version will extract them into a top-level `shared/` directory.

## Versioning

The plugin version tracks Nano CMS releases: plugin `v1.x.y` is tested against Nano CMS `v1.x.y`. The skills are forward-compatible with patch releases of Nano, but you may want to upgrade the plugin alongside major/minor releases of Nano itself.

## Safety guarantees

- `ssh-deploy` refuses to overwrite an existing Nano install (checks for `core/Bootstrap.php` at target before init).
- `ssh-content` backs up affected DB tables before any write.
- `ssh-download` backs up local state to `/tmp/nano-download-backup-<timestamp>/` before destructive refresh.
- `upgrade` only touches files declared in `engine-manifest.json`. User content (`theme/`, `storage/`, `.env`, `.deploy/`, etc.) is never overwritten.
- All SSH config files (`.deploy/ssh.json`) are written with `chmod 0600` and ignored from git.

## Reporting issues

Open an issue at https://github.com/rickfalaschi/nano-cms-plugin/issues — include the skill name, the command/intent that triggered it, and the relevant output (sanitized of credentials).

## License

MIT
