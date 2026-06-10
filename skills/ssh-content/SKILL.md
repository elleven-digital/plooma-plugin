---
name: ssh-content
description: Update content on a Ellev (formerly Nano CMS) site that's deployed on a remote server, via SSH. Creates/edits/publishes posts, services, pages, and any other content type defined in the site's `theme/site.json` — schema-aware, so it works on ANY Ellev site without knowing fields ahead of time. Reuses `.deploy/ssh.json` from ellev:ssh-deploy/ellev:ssh-download. Backs up the affected database tables before any write. Triggers whenever the user wants to manage live content remotely — phrases like "cria um post no blog do site X", "publica esse draft", "muda o texto do hero da home", "atualiza a página de serviços", "lista os drafts", "edita o post sobre Y", "altera o eyebrow do site", "create a blog post on the deployed site", "publish all drafts", "edit the about page on production". Triggers in Portuguese and English. The skill discovers types and fields at runtime by calling `bin/ellev item:types` and `bin/ellev <kind>:schema` on the remote, so it adapts to whatever the site has — posts, services, cases, events, team members, pages with custom fields, etc. Do NOT use for: (a) bulk media uploads (out of scope — use admin), (b) changing the schema itself / adding new content types (that's `theme/site.json`, edit locally and deploy), (c) editing templates or theme code (use a code editor + ellev:ssh-deploy), (d) sites that are NOT deployed remotely yet (use the local admin or a local-only content skill).
---

# Manage Ellev content on a deployed server

This skill lets you create, edit, and publish content on a live Ellev site over SSH, using the `bin/ellev item:*` and `bin/ellev page:*` commands the Ellev exposes. It's schema-aware: it figures out what content types and fields the specific site has by asking the server, then guides the user through changes in their own terms.

## Why SSH and not the admin web UI

Two reasons:
1. **Bulk and natural language.** "Publish all drafts in category X" or "create 5 posts from these topic ideas" is a 2-second skill call vs minutes of clicking.
2. **Programmatic edits during sync.** When you're already in the terminal building/deploying, jumping to a browser breaks flow.

The admin UI is still the right choice for: media uploads, layout changes, complex form-heavy edits, and anyone who isn't comfortable with this workflow.

## Required server-side dependency

This skill talks to `bin/ellev` content commands that ship with Ellev commit `dcebc50` or later (`item:types`, `item:schema`, `item:create`, etc.). If the remote server has an older Ellev, **upgrade it first** with the `ellev:ssh-deploy` action `update` or via `ellev:upgrade` on a local clone followed by deploy.

A quick way to check: `ssh <target> "cd <remote_path> && ./bin/ellev item:types"` — if it errors with "Unknown command: item:types", the server needs an upgrade.

## How the skill works at a glance

```
0. Load .deploy/ssh.json from current folder
1. Discover    — what types/pages does THIS site have?
2. Plan        — translate user intent into a concrete operation
3. Validate    — dry-run on remote, see if it'd work
4. Confirm     — show the user the exact thing about to happen
5. Backup      — mysqldump the affected tables (items, pages)
6. Execute     — run the real bin/ellev command via SSH
7. Report      — what changed, where backup is, how to roll back
```

Reads (list, get, schema) skip phases 5–6: they're side-effect-free.

## Phase 0 — Locate the site

The skill operates on **the current working directory**. It expects `.deploy/ssh.json` in the cwd — the same file that ellev:ssh-deploy and ellev:ssh-download create. If it's missing:

- Tell the user: "Não encontrei `.deploy/ssh.json` aqui. Esta skill precisa de uma config de SSH pra conectar no site. Use `ellev:ssh-deploy` (`init`) ou `ellev:ssh-download` antes pra criar essa config."
- Don't try to gather credentials yourself — the other skills already handle that with proper validation.

## Phase 1 — Discover what's on the site

Run `scripts/discover.sh --config .deploy/ssh.json` and parse the JSON it returns. You'll get:

```json
{
  "ok": true,
  "ssh_target": "user@host",
  "remote_path": "/var/www/site",
  "item_types": [
    {"type": "posts", "label": "Posts", "has_page": true, "slug": "blog"},
    {"type": "services", "label": "Serviços", "has_page": false}
  ],
  "pages": [
    {"key": "home", "label": "Home"},
    {"key": "sobre", "label": "Sobre"}
  ]
}
```

If discovery fails (SSH issue, missing `bin/ellev content commands`), surface the error verbatim so the user can fix the upstream problem.

**Use this discovery output as ground truth.** Don't assume any site has "posts" or "pages" — many don't, or call them differently. Match the user's request against what actually exists.

## Phase 2 — Map user intent to an operation

User asks in natural language; you translate into one of:

| User intent | Operation |
|---|---|
| "cria um post sobre X" | `item:create posts` (or whatever the post-like type is called) |
| "publica o post X" | `item:publish <type> <slug>` |
| "muda o texto Y para Z na home" | `page:update home` with `{fields: {Y: Z}}` |
| "lista todos os drafts" | `item:list <type> --status=draft` |
| "qual o conteúdo do post X" | `item:get <type> X` |
| "deleta o post X" | `item:delete <type> X --confirm` (with explicit user confirm) |

If the user's request doesn't fit any operation, say so plainly — don't invent. Some adjacent things this skill **doesn't** do:
- Add a new content type → that's editing `site.json` locally then deploying
- Upload an image → admin UI for now
- Edit a template's HTML → not this skill

When the request requires fields, fetch the schema first:
```bash
ssh <target> "cd <remote_path> && ./bin/ellev item:schema posts --format=json"
```

The schema response lists every field with `name`, `type`, `label`, and `required`. Use this to:
- Ensure required fields are present (ask the user for any missing)
- Pick reasonable defaults for optional ones
- Validate types client-side before even sending

## Phase 3 — Validate on the remote (dry-run)

For any create or update, run the operation with `--dry-run --format=json` first:

```bash
echo '<JSON>' | ssh <target> "cd <remote_path> && ./bin/ellev item:create posts --json-stdin --dry-run --format=json"
```

The remote validates the same way it would on a real write — required fields, type checks, slug collisions. If it returns `{"ok": false, "error": "..."}`, surface the error and let the user fix the input. Only proceed to phase 4 on `{"ok": true, "dry_run": true, ...}`.

This is the most important step for destructive workflows. It catches bad JSON before it touches the database.

## Phase 4 — Confirm with the user

Show a clean preview of exactly what will happen:

**For create:**
```
Vou criar um post no site <ssh_target>:

  type:    posts
  slug:    como-escolher-um-advogado
  title:   Como escolher um advogado?
  status:  draft
  fields:
    content:        "Quando você precisa…" (842 chars)
    author_name:    "Henrique Falaschi"
    read_minutes:   8

Continuar? (y/N)
```

**For update:**
```
Vou atualizar o post 'como-escolher-um-advogado' no <ssh_target>:

  Campos que vão mudar:
    content:  (era 842 chars) → (vai para 1.205 chars)

  Outros campos preservados.

Continuar? (y/N)
```

**For destructive operations (delete, mass publish):**
- Show item count, list slugs to be affected
- Require explicit `y` confirmation
- For a single delete, fine; for "delete all drafts", show the list AND require uppercase `DELETE` typed by hand

**For pages:** include the page key and which fields change. Pages are usually the highest-stakes edits because they're the live homepage / about page / etc.

## Phase 5 — Backup before write

Run `scripts/backup.sh --config .deploy/ssh.json --tables items,pages` before ANY write. It:
1. Runs `mysqldump --single-transaction --no-tablespaces` on the remote DB for the listed tables
2. Streams the dump back to local `/tmp/ellev-content-backup-<ts>.sql`
3. Reports the path + size

Tell the user the backup path so they can `mysql ... < <path>` to restore if needed. The backup is automatic — the user doesn't have to ask.

For pure read operations (list, get, schema), skip backup.

## Phase 6 — Execute the write

Run `scripts/write.sh --config .deploy/ssh.json --action <action> [--target <type-or-key>] [--slug <slug>] [--confirm]`, with the JSON payload (when needed) piped in via stdin.

Supported actions:
- `item:create <type>`
- `item:update <type> <slug>`
- `item:publish <type> <slug>`
- `item:unpublish <type> <slug>`
- `item:delete <type> <slug>` (requires `--confirm`)
- `page:update <key>`

The script SSHs in, runs `bin/ellev <action> --format=json`, captures stdout, and returns it. Errors come back as structured `{"ok": false}` JSON — handle them, don't pretend they didn't happen.

## Phase 7 — Report back

After execution:

```
✓ Post 'como-escolher-um-advogado' criado.

  Site:        <ssh_target>
  ID:          47
  Status:      draft  (não está visível ainda — use 'publica esse post' pra publicar)
  URL futura:  https://<site>/blog/como-escolher-um-advogado

  Backup:      /tmp/ellev-content-backup-20260429-1432.sql
  Rollback:    se algo deu errado: mysql -u<user> ... < /tmp/ellev-content-backup-...
```

For batch operations: report each operation's outcome, total successes/failures, single backup path covering the whole batch.

## Conversational patterns

The skill should feel like talking to a content editor, not running CLI commands. Some patterns that work well:

### Editing existing content by description, not slug

User: *"muda o título do post mais recente sobre advocacia para 'X'"*

Skill flow:
1. `item:list posts --search=advocacia --status=any --limit=5 --format=json`
2. Show top 3 titles with dates, ask which one
3. User confirms → `item:update posts <slug> --json='{"title":"X"}'`

### Publishing in bulk by criteria

User: *"publica tudo que está em draft há mais de uma semana"*

1. `item:list posts --status=draft --format=json` (also services, etc.)
2. Filter client-side by `updated_at` older than 7 days
3. Show the list, get confirmation
4. Loop: `item:publish posts <slug>` for each
5. Report N published, paths

### Translating descriptions to fields

User: *"cria um post chamado 'Foo' com o corpo sendo o texto que eu colei abaixo"*

1. Discover `posts` type → fetch its schema
2. Notice: `title` required (use "Foo"), `content` is the richtext field, `author_name` optional
3. Build JSON: `{"title":"Foo","fields":{"content":"<pasted text>"}}`
4. Dry-run → confirm → execute

If the user pastes raw text and the schema expects HTML/richtext, wrap each paragraph in `<p>...</p>` (Ellev's richtext fields render as HTML). For Markdown input, you can either render to HTML in the skill or leave it as-is and let the theme decide — pick based on what the schema field's `type` is and the user's evident intent.

### Asking the right clarifying questions

If a required field is missing and you can't reasonably infer it, ask. Don't make up an author name or a category. Phrasing matters: don't say "what should `author_name` be?" — say "Quem é o autor desse post?" Translate field labels into human terms.

## Safety guarantees

- Never write without dry-running first
- Never write without backing up first
- Never delete without explicit `--confirm` AND user confirmation in chat
- Never assume a content type/field exists — always discover first
- Never silently overwrite — show the diff (or the changed keys) before saving
- Never invent slugs — auto-generation is OK, but it's the server's job (`item:create` does it). For updates, the slug is provided by the user.

## Edge cases

- **Server doesn't have `bin/ellev item:types`**: Pre-flight check fails → tell user the remote needs Ellev upgraded (commit dcebc50 or later). Don't try alternatives.
- **`site.json` defines a field type the skill doesn't recognize**: Pass through untouched. The Content validator is permissive — it only enforces required + type sanity, and it lets unknown fields through. The skill should do the same.
- **Slug collision on create**: the server will reject with `"Slug already exists for type 'X': Y"`. Suggest a variant or ask the user.
- **Field is a `repeater`**: pass an array of objects matching the inner field schema. Discover via `item:schema` to see what each repeater item should look like.
- **Field is `image`**: store the value as a path or URL string. Actual upload of new images is OUT OF SCOPE — tell the user to upload via admin first, then reference the URL.
- **Network drops mid-write**: writes are single SQL statements, so they either succeed or don't. The backup is your rollback. Don't auto-retry — re-running might create duplicates.
- **User wants to undo**: the backup at `/tmp/ellev-content-backup-<ts>.sql` is the rollback. It's a full table dump — `mysql ... < <path>` brings the items/pages tables back to pre-write state. Tell the user this if they ask.

## Common host gotchas

- **`mysqldump` not in PATH on remote**: shared hosts often need `/usr/bin/mysqldump`. The backup script tries the bare command first; if that fails, point the user to running `which mysqldump` on the remote and pass the path via `--mysqldump=<path>`.
- **Hostinger / cPanel restrict `LOCK TABLES`**: the backup script uses `--single-transaction --no-tablespaces` to work around this — same flags as ellev:ssh-deploy/download.
- **PHP CLI not in default PATH**: `bin/ellev` uses `#!/usr/bin/env php`. If that fails, the user can set `php` in their remote shell's PATH or pass an absolute path via `--php=<path>` (write.sh and discover.sh both support this).

## Scripts

The actual operations live in `scripts/`. Each:
- Takes `--config <path>` pointing to the JSON config
- Resolves SSH (alias OR direct host/port/user/key) via shared `_lib.sh`
- Returns JSON on stdout for programmatic parsing
- Exits non-zero on hard failure; structured errors (validation) come back as `{"ok": false, ...}` on stdout with exit 0

| Script | Purpose |
|---|---|
| `_lib.sh` | Shared helpers: `cfg_get`, `resolve_ssh_cmd`, `confirm_yes`, logging |
| `discover.sh` | One-shot discovery: types + pages + remote info, returns single JSON |
| `backup.sh` | mysqldump remote tables to local `/tmp/ellev-content-backup-<ts>.sql` |
| `write.sh` | Execute one item:* or page:* command via SSH; passes through `--format=json` |

Read the scripts to see the exact commands they run. They're the source of truth.

## What this skill does NOT do

- Edit `theme/site.json` (that's the schema — change locally and deploy)
- Edit template PHP files (use an editor + ellev:ssh-deploy)
- Upload media files (use the admin UI; this skill only references existing media by URL/path)
- Manage taxonomies (terms/categories) at write level — only filtering items by existing terms is supported
- Manage form submissions or site options — those are admin-UI responsibilities
- Touch user accounts — out of scope for content management

## Variants the user might phrase

All of these should trigger and work correctly:

**Portuguese:**
- "cria um post no blog do expmark"
- "publica todos os drafts"
- "muda o título do hero da home"
- "atualiza o eyebrow da página de serviços"
- "lista os posts publicados nesse mês"
- "deleta o post de teste"
- "altera o conteúdo do campo X na página Y"
- "tem alguma página chamada `tarifas`? me mostra"

**English:**
- "create a blog post on the deployed site"
- "publish all drafts on the prod site"
- "update the hero text on the about page"
- "list draft posts"
- "edit the post about X on production"
- "what content types does this site have?"
