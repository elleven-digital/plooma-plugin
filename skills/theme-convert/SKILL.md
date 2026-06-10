---
name: theme-convert
description: Convert a folder of static HTML/PHP templates into a Ellev (formerly Nano CMS) theme. Reads pages in the current directory, extracts shared header/footer into partials, identifies editable fields (titles, hero copy, images, repeating blocks), proposes a `site.json` schema with pages and item types, then generates Ellev-compatible PHP templates with `field()`, `option()`, `image_url()`, and other Ellev helpers wired in. Also pre-populates the admin panel with the same content that was hardcoded in the source — pages, items, taxonomy terms, and global options — via a one-shot seed script, so the user opens admin to a populated site, not empty fields. If the current directory is NOT inside an existing Ellev install, this skill creates `./theme/`, moves the source files there, then auto-installs Ellev (delegates to ellev:install) before doing the conversion. Use this skill whenever the user has static HTML/PHP files (a downloaded template, a static site, a design mockup with markup) and wants to turn them into a Ellev theme — phrases like "transforma esses html em tema do nano", "converte essa pasta de templates para nano", "vira isso aqui em theme", "tenho um modelo estático e quero usar no nano cms", "build a nano theme from these html files". Triggers in Portuguese and English. Always operates in plan-then-execute mode: produces a full mapping (files → pages, blocks → fields, partials, options) for user approval before generating any output. Do NOT use for: (a) installing a fresh Ellev without conversion (that's ellev:install), (b) modifying an already-converted theme, (c) editing site.json schema in an established project, (d) answering questions about Ellev helpers/syntax. Mentioning HTML, PHP, or themes alone does NOT trigger — only explicit conversion intent does.
---

# Convert static templates into a Ellev theme

This skill turns a folder of static HTML/PHP pages into a working Ellev theme. It analyzes the source, proposes a schema, gets user approval, then generates the theme.

## Goal

By the end:
- Source HTML/PHP analyzed; shared partials extracted; pages and item types identified
- `theme/site.json` written with a coherent schema (pages, item types, options, fields)
- `theme/templates/page-*.php` and `theme/templates/single-*.php` generated with Ellev helpers wired in (`field()`, `option()`, `image_url()`, `get_header()`, `get_footer()`)
- `theme/partials/header.php` and `theme/partials/footer.php` extracted (or wired up if user already provided them)
- Assets (CSS, JS, images) moved to `theme/`
- `./bin/ellev page:sync` runs successfully and `./bin/ellev schema:validate` reports OK
- **Admin pre-populated with the original content**: pages, item type instances (cases, posts, etc.), taxonomy terms, and global options all seeded from what was hardcoded in the source. The user opens admin and sees the same content as the original site — ready to refine, not start from scratch. The site renders correctly at `/` immediately.

The user iterates after by refining the seeded content. The skill's job is the structural conversion + faithful content migration.

## Phase 0 — Locate self in the filesystem

The skill runs from inside the folder containing the HTML/PHP source. Two scenarios:

**Scenario A — Inside an existing Ellev's `theme/` folder.**
Detect by checking if `../core/Bootstrap.php` exists. If yes, this is the destination — generate files in place (current dir).

**Scenario B — Folder of templates outside any Ellev.**
Detect by checking for absence of `core/Bootstrap.php` (here or one level up). In this case:
1. Tell the user: "Detected this folder isn't inside a Ellev install. Plan: create `./theme/`, move all HTML/PHP/asset files into it, install Ellev in current dir, then convert. OK?"
2. On confirmation:
   - `mkdir theme`
   - Move all source files (HTML/PHP/CSS/JS/images, but NOT `.git`, `.github`, or any dotfiles) into `theme/`
   - Invoke the **ellev:install** skill to set up Ellev in the current dir (it'll clone into root, write `.env`, run installer)
   - After install completes, the source files are now at `./theme/*`. Continue conversion from inside `./theme/`.

Reject and abort if neither scenario applies cleanly (e.g. `theme/` exists but is empty + we're nowhere) — ask the user to clarify.

## Phase 1 — Source analysis

Read every file in the working dir. Classify into:

- **HTML/PHP page candidates**: `*.html`, `*.php` (excluding clearly-non-pages like `.htaccess`, `composer.json`)
- **Likely partials already extracted**: `header.html`, `header.php`, `footer.html`, `footer.php`, `nav.html`, etc. — if these exist, **use them as-is** (don't re-extract from pages).
- **Assets**: `*.css`, `*.js`, `images/`, `img/`, `assets/`, `fonts/`
- **Junk to ignore**: `node_modules/`, `vendor/`, `.git/`, `.DS_Store`, `Thumbs.db`

For each page candidate, build a quick mental model:
- What's the `<title>`?
- What's in `<head>` beyond `<title>` (meta, links, scripts)?
- What's the structure — is it a single content block, or a complex composition?
- Does the file name suggest a content type? (`index.html` = home, `blog.html` = blog archive, `post.html` = post single, etc.)

### Detect shared partials

Compare the markup of all page candidates. Find blocks that are byte-for-byte (or near-byte-for-byte) identical across pages — typically the `<header>` and `<footer>`. Those are the partial candidates.

If the user already provided `header.html`/`footer.html`/etc. as separate files, **trust those** — don't extract from pages. Just plan to wire each page's `<?php get_header(); ?>` and `<?php get_footer(); ?>` to those.

### Classify pages vs. item types

A **page** is a single, named thing the user navigates to (`home`, `sobre`, `contato`).

An **item type** is a content kind with multiple instances, with one template that renders any instance (`post`, `service`, `case-study`).

Heuristics — when a page is OBVIOUSLY a single template:
- Filenames like `post.html`, `case-study.html`, `service.html` (singular noun, often referenced from a list page)
- A list/archive page (`blog.html`, `cases.html`) clearly loops over items of this type — open it and look for repeated card markup
- Multiple files with similar structure: `post-1.html`, `post-2.html`, `post-foo-bar.html` are clearly instances

When obvious, decide automatically. **When ambiguous**, ask the user before committing in the plan: "I see `services.html` and `service.html` — should `service` be an item type with `services.html` as the archive (configured as a page in site.json), or should both be standalone pages?"

### Detect repeating blocks within a page

Look for adjacent siblings with the same markup pattern (e.g., 3 testimonial cards, 4 stats blocks). These are **repeater field** candidates — capture them and propose a repeater in site.json.

### Detect global content vs. page-specific content

- Header navigation links → `option('nav.links')` (a global repeater)
- Footer contact info (phone, email, address, social) → `option('contato')` (a global option group)
- Logo → still hardcoded SVG/img in `partials/header.php` (per Ellev's convention — site logo is theme-level, not editable per project unless requested)
- Per-page hero, body, CTAs → page-level `field()`s

### Capture content alongside structure

For every field, repeater row, item instance, taxonomy term, and option you identify, **also capture the actual content** that lives there in the source. The skill doesn't just create the empty schema — it migrates the content too.

Concretely, while reading each PHP file, write down:

- **Page-level field values** — every literal title, lead, paragraph, CTA label/URL, badge text, kicker, heading, body block. The text inside `<h1>`, the lead `<p>`, the manifesto paragraphs, the FAQ Q&A pairs, the process step descriptions. Each goes into the page's seed.
- **Repeater row content** — every entry in inline arrays like `$projects = [...]`, `$jobs = [...]`, `$steps = [...]`, `$values = [...]`, `$awards = [...]`, `$ticker_items = [...]`, `$clients = [...]`. Each row's full data.
- **Item type instances** — when an archive page contains a `$projects` or `$posts` array (or repeated `<article>` cards), each row becomes a seeded item with all its fields.
- **Taxonomy terms** — categories used in filter chips and `'cats' => [...]` arrays. Capture the term slugs and human labels.
- **Option content** — nav link list, contact info (email, phone, whatsapp URL, address, hours), social URLs (Instagram, LinkedIn, etc.), recurring stats (the same `8+ years / 180+ brands / 635+ content / 4 countries` block that appears on multiple pages becomes one shared option).
- **Image references** — capture the relative path as found (e.g., `assets/cases/wm-educacao.jpg`). Don't try to upload to the media library; the seeder will write the path string and Ellev's `image_url()` resolves bare paths so the page renders immediately.
- **Richtext / HTML body content** — inline `<p>`, `<ul>`, `<blockquote>` content inside body sections. For richtext fields, capture the inner HTML so it round-trips faithfully into TipTap.

The user is going to see this captured content in the plan (Phase 2) and approve the seed before it runs (Phase 3.6). So extraction must be **complete and faithful** — never silently drop content. If a section has 6 services with 18 fields total, capture all 18.

## Phase 2 — Build the plan

Produce a structured plan document with these sections:

```
## Conversion plan

### Files detected
- <file> → <classification> (template: <output-path>)
...

### Shared partials
- header: extracted from <files>  →  partials/header.php
- footer: extracted from <files>  →  partials/footer.php
(or: "Using existing header.php / footer.php as-is")

### Pages
**home** (from `index.html`):
  - <field_name> (<type>) ← derived from <selector or quote>
  - ...

**sobre** (from `sobre.html`):
  - ...

### Item types
**post** (from `post.html`, listed in `blog.html`):
  - has_page: true
  - slug: blog
  - taxonomies: [categoria]
  - fields: thumbnail (image), excerpt (textarea), body (richtext), ...

### Options
- nav.links (repeater) ← extracted from <nav>
- contato (phone, email, address) ← from footer

### Assets
- styles.css → theme/style.css
- main.js → theme/scripts.js
- images/* → theme/images/*

### Pre-populated content (auto-seed)

The admin will be filled with the content currently hardcoded in the source. After the conversion, the user opens admin to a populated site — not empty fields. Highlights of what'll be seeded:

**Pages** (samples — full set in the seeder):
- home: hero_title (4 lines), hero_lead, badge ("1º Lugar — Prêmio Limitless..."), ticker (8 items), manifesto (title + 2 paragraphs), services_preview (6 items), quote (4 lines + sign), clients (16 names), contact_kicker
- sobre: pillars (3 entries with photos), awards (4 entries), values_strip (6 items), manifesto, CTA
- ...one bullet per page

**Item type instances**:
- `case`: 9 items (wm-educacao, essenza, real-estate, vibecon, cm-engenharia, fabex-solar, deorum, living-pink, ...)
- `post`: 13 items (pantone-2026, rd-summit, shorts-tiktok, ...)

**Taxonomy terms** (`categoria`): branding, design, social, trafego, foto, video, estrategia, performance

**Options**:
- nav.links: 5 entries (Sobre / Serviços / Cases / Blog / Contato)
- contato: email, phone_label, whatsapp_url, address, hours
- social: 4 URLs
- stats: 4 entries (shared across home and sobre)
- footer: tagline, copyright_name

**Images**: seeded as path strings (e.g., `theme/assets/cases/wm-educacao.jpg`). Renders immediately. User can later replace with admin uploads.

### Manual review needed
- <anything ambiguous>
- <fields the heuristics weren't sure about>
- <any content the seed will skip and require manual entry — e.g., third-party form embeds, dynamic widgets>
```

Show this plan to the user. **Don't generate any files yet.**

Ask: "Confirm to proceed, or tell me what to adjust." Iterate on the plan based on feedback. When confirmed, move to Phase 3.

## Phase 3 — Execute

Generate everything declared in the plan, in this order:

### 3.1. Write `site.json`

Build the schema from the plan. Conventions:

- Top-level `site` block: `name`, `description`, `language: "pt-BR"` (or detect from `<html lang>`). NO `url` — that's deployment-specific (.env)
- `pages` keyed by lower-case slug: `home`, `sobre`, `contato`, etc.
- Page `template` field: `page-<key>.php`
- Page `url` field: `/` for home, `/<key>` otherwise (omit if matches the default — Ellev falls back to `/<key>`)
- `item_types` keyed by lower-case singular: `post`, `service`
- Item types with `has_page: true` get `slug`, `template`, optionally `taxonomies`. Embed-only types use `has_page: false` and skip `slug`/`template`
- `options` for global concerns (nav, contato, rodape, etc.)
- DON'T add a built-in SEO field group — Ellev handles SEO automatically for paged content (`Config::seoFields()` is built-in)

### 3.2. Write `partials/header.php` and `partials/footer.php`

Each follows Ellev conventions:

```php
<?php
// Theme-level config that varies per page
$siteName = (string) site('site.name', 'Site');
$lang = (string) site('site.language', 'pt-BR');
$ctx = current_context();
$pageTitle = $ctx ? the_title($ctx) : '';

$seoMetaTitle = $ctx ? trim((string) (field('meta_title') ?? '')) : '';
$seoMetaDesc  = $ctx ? trim((string) (field('meta_description') ?? '')) : '';
$seoOgImage   = $ctx ? field('og_image') : null;

$fullTitle = $seoMetaTitle !== ''
    ? $seoMetaTitle
    : ($pageTitle !== '' && $pageTitle !== $siteName ? $pageTitle . ' — ' . $siteName : $siteName);
?>
<!DOCTYPE html>
<html lang="<?= e($lang) ?>">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= e($fullTitle) ?></title>
<?php if ($seoMetaDesc !== ''): ?>
    <meta name="description" content="<?= e($seoMetaDesc) ?>">
<?php endif; ?>
<!-- og + twitter tags - mirror metadesc + ogimage when set -->
<link rel="stylesheet" href="<?= e(asset('theme/style.css')) ?>">
<?php tracking_head(); ?>
</head>
<body>
<?php tracking_body_start(); ?>
<header class="site-header">
    <!-- migrated header markup -->
    <nav>
        <?php foreach ((array) option('nav.links', []) as $link): ?>
            <a href="<?= e(str_starts_with($link['url'], 'http') ? $link['url'] : url($link['url'])) ?>">
                <?= e($link['label']) ?>
            </a>
        <?php endforeach; ?>
    </nav>
</header>
```

Footer mirrors this with `tracking_body_end()` before `</body>` and pulls contact info from `option('contato.*')`.

### 3.3. Write each page template (`page-<key>.php`)

Pattern:

```php
<?php /** @var \Ellev\TemplateContext $page */ ?>
<?php with_context($page, function () { ?>
<?php get_header(); ?>

<!-- migrated page markup, with text/images replaced by field() / image_url() -->
<section class="hero">
    <h1><?= field('hero_title') /* trusted: HTML allowed */ ?></h1>
    <?php $heroSrc = image_url(field('hero_image'), 'feat'); ?>
    <?php if ($heroSrc): ?>
        <img src="<?= e($heroSrc) ?>" alt="<?= e(image_alt(field('hero_image'))) ?>">
    <?php endif; ?>
    <?= field('hero_intro') /* trusted: richtext */ ?>
</section>

<!-- repeater example -->
<?php $stats = (array) field('stats', []); ?>
<?php if (!empty($stats)): ?>
    <ul class="stats">
        <?php foreach ($stats as $stat): ?>
            <li>
                <strong><?= e($stat['number'] ?? '') ?></strong>
                <span><?= e($stat['caption'] ?? '') ?></span>
            </li>
        <?php endforeach; ?>
    </ul>
<?php endif; ?>

<?php get_footer(); ?>
<?php }); ?>
```

Conventions to follow strictly (these are why Ellev works):
- `<?= e($value) ?>` for any user-typed plain-text field — escapes by default
- `<?= field('foo') /* trusted */ ?>` for richtext fields and HTML-allowed text fields (with the comment so future editors know it's intentional)
- `image_url($value, $size)` always, never raw image field values (which are integer IDs)
- `image_alt($value)` for alt text
- `url('/path')` for internal links — never hardcode `/sobre`
- `option('nav.links', [])` with default `[]` for repeaters
- Wrap everything in `with_context($page, function () { ... });` so `field()` etc. work without explicit context

### 3.4. Write each item type single template (`single-<type>.php`)

Same pattern, but the variable is `$item`:

```php
<?php /** @var \Ellev\TemplateContext $item */ ?>
<?php with_context($item, function () { ?>
<?php get_header(); ?>

<article>
    <h1><?= e(the_title()) ?></h1>
    <?= field('body') /* trusted: richtext */ ?>
</article>

<?php get_footer(); ?>
<?php }); ?>
```

The archive page (e.g. `page-blog.php`) uses `items('post')` to loop. Ellev doesn't auto-route `/<type-slug>` archives anymore — each archive must be a configured page in `site.json`. Make sure the plan's `pages.blog` template loops items.

### 3.5. Move assets

- Top-level CSS files → `theme/style.css` (concatenate if multiple — explain to user)
- Top-level JS files → `theme/scripts.js` (concatenate if multiple)
- `images/`, `img/`, `assets/img/` → `theme/images/`
- `fonts/` → `theme/fonts/`

If the original HTML referenced `<link href="styles.css">`, the converted template references `<?= e(asset('theme/style.css')) ?>` instead.

### 3.6. Pre-populate the admin (seed script)

After `page:sync` runs, the page records exist but their `fields` are empty. The admin is structurally correct but visually empty — the user has to copy/paste content from the original PHP files into every form. That's tedious and error-prone. Instead: generate a **one-shot seed script** that writes every captured field, item, term, and option directly into the database, so the admin opens already populated.

**Inspect Ellev's models before writing the seed.** Don't guess the API. Read these files to learn the exact write surface:

- `core/Models/Page.php` — how to find a page by key and save its fields
- `core/Models/Item.php` — how to create new items, set status, attach taxonomy terms
- `core/Models/Term.php` — how to create taxonomy terms
- The settings/options write API — grep for `Setting`, `Settings`, `option_set`, or how the admin's options edit form persists. It's likely a `Setting` model with `set()` / `save()`, or a direct PDO write to a `settings` table with `setting_key = "options.{key}"`.

If you can't confidently find the option write API after a few minutes of reading, **stop and tell the user**: "I can't find how options are written in this Ellev version. I'll seed pages, items, and terms — you'll fill in options manually via admin." Don't ship a broken seed.

**Where to put it.** Write `theme/install/seed.php`. It's a one-shot script bootstrapped against Ellev's core:

```php
<?php
// One-shot seed: pre-populate admin with content migrated from the original source.
// Safe to re-run — guards at the top check if seed has already been applied.

require __DIR__ . '/../../core/Bootstrap.php';

use Ellev\Models\Page;
use Ellev\Models\Item;
use Ellev\Models\Term;
// ...other models you discovered (Setting, etc.)

// --- Idempotency guard ---
// If a known field on the home page is already populated, the seed has run.
// Bail to avoid clobbering the user's edits.
$home = Page::resolveByKey('home');
if ($home && !empty($home->field('hero_title'))) {
    fwrite(STDOUT, "Seed appears already applied (home.hero_title is set). Skipping.\n");
    exit(0);
}

// --- Options ---
// Use whatever API your model inspection turned up. Pseudocode example:
Setting::set('options.nav', [
    'links' => [
        ['key' => 'sobre',    'label' => 'Sobre',    'url' => '/sobre'],
        ['key' => 'services', 'label' => 'Serviços', 'url' => '/servicos'],
        // ...all extracted nav links
    ],
    'cta_label' => 'Começar projeto',
    'cta_url'   => '/contato',
]);
Setting::set('options.contato', [
    'email' => 'contato@expmark.com.br',
    'phone_label' => '+55 47 98862-7252',
    'whatsapp_url' => 'https://wa.me/5547988627252',
    // ...
]);
// ...other option groups

// --- Taxonomy terms (create BEFORE items so we can attach them) ---
$catBranding = Term::create(['taxonomy' => 'categoria', 'name' => 'Branding', 'slug' => 'branding']);
$catDesign   = Term::create(['taxonomy' => 'categoria', 'name' => 'Design Gráfico', 'slug' => 'design']);
// ...all categories

// --- Items ---
$wmEducacao = Item::create([
    'type'   => 'case',
    'title'  => 'Como uma marca pode refletir propósito, credibilidade e impacto no mercado?',
    'slug'   => 'wm-educacao',
    'status' => 'published',
    'fields' => [
        'client'   => 'WM Educação',
        'year'     => '2026',
        'sector'   => 'Educação',
        'cover'    => 'theme/assets/cases/wm-educacao.jpg', // path string, not media id
        'excerpt'  => 'Descubra como a Expmark posicionou...',
        'featured' => true,
        'blocks'   => [
            ['type' => 'image-wide', 'image' => 'theme/assets/cases/wm-educacao.jpg'],
            ['type' => 'section', 'heading' => 'O desafio', 'body' => '<p>A WM Educação precisava...</p><p>...</p>'],
            ['type' => 'image-pair', 'image' => 'theme/assets/cases/vibecon.png', 'image_2' => 'theme/assets/cases/essenza.jpg'],
            // ...all blocks captured from case.php
        ],
    ],
]);
$wmEducacao->setTerms('categoria', [$catBranding->id, $catDesign->id]);
// ...all items

// --- Pages ---
// page:sync already created the row. Save just the fields JSON.
$home->save(['fields' => [
    'hero_badge_strong' => '1º Lugar',
    'hero_badge_text'   => 'Prêmio Limitless RD Station 2024',
    'hero_title'        => '<span><em>Nós</em></span> <span>impulsionamos</span> <span>negócios, <i>pessoas</i></span> <span>e conexões.</span>',
    'hero_lead'         => 'Desde 2018, uma agência full-service que transforma marcas regionais...',
    'ticker_items' => [
        ['symbol' => '★',  'label' => 'RD Station Premium'],
        ['symbol' => '»»', 'label' => '1º Lugar Limitless 2024'],
        // ...all 8
    ],
    'manifesto_title' => '<span>Presença não é só estar online.</span> <span class="manifesto__em">É ser lembrado</span> <span>no digital e <i>fora dele.</i></span>',
    'manifesto_paragraphs' => [
        ['text' => 'A gente não entrega post...'],
        ['text' => 'Somos um time de estrategistas...'],
    ],
    'services_preview' => [
        ['name' => 'Marketing 360º', 'desc' => 'Gestão estratégica completa...', 'tags' => 'Estratégia, Inbound, SEO'],
        // ...all 6 services
    ],
    // ...every other captured field
]]);
// ...all pages

echo "Seed complete.\n";
```

**Image fields → path strings, not media uploads.** Set them to the original relative path (e.g. `theme/assets/cases/wm-educacao.jpg`). Ellev's `image_url()` accepts path strings as input, so the page renders with the original images immediately. The user can later upload via the media library and the integer ID replaces the string. **Don't try to programmatically upload to the media library** — too brittle, too easy to corrupt, and it's not what the user asked for.

**Item status.** Items go in as `'status' => 'published'` so the archive pages show them. Without this, the archive will appear empty.

**Order of operations.** Terms BEFORE items (so item creation can `setTerms` to existing IDs). Options can go anywhere. Pages last (they're already created by `page:sync`, you're just filling fields).

**Idempotency is non-negotiable.** The script must be safe to re-run. Guard at the top with a check on a known seeded value (e.g. home.hero_title). If the seed already ran, exit cleanly. This protects user edits from being clobbered if they re-run by accident.

**What NOT to seed.**
- SEO fields (`meta_title`, `meta_description`, `og_image`) — leave empty so pages fall back to their natural title and the user fills these intentionally
- Form submissions, user data, anything time-sensitive
- Image MEDIA records (we use path strings instead)
- Anything that wasn't in the user-approved plan

### 3.7. Validation

After writing all files:

```bash
./bin/ellev schema:validate
./bin/ellev page:sync
php theme/install/seed.php
```

If `schema:validate` errors, surface the error and offer to fix.

If `page:sync` reports new pages added, that's expected.

If the seed errors mid-way, surface the error and stop. Common causes:
- **Model API mismatch** — your inspection of Ellev's source produced wrong assumptions. Re-read the model file, fix the call, re-run. The script's idempotency guard means re-running is safe (it'll skip if home is already populated, otherwise pick up where it left off).
- **Unique slug constraint** — an item with that slug already exists. Means a previous partial seed ran. Either delete the half-seeded items and re-run, or add per-item existence checks.
- **Missing taxonomy term** — order of operations is wrong. Make sure all `Term::create` calls happen before items that reference them.
- **Empty option write** — your option API guess didn't actually persist. Verify by reading from the DB directly. If the API surface isn't clear, fall back to direct PDO writes against the `settings` table.

## Phase 4 — Report

Tell the user what was generated, with paths. Then list:

**Pre-populated in admin** (from `theme/install/seed.php`):
- N pages — all hero/CTA/manifesto/repeater fields filled with the original copy
- N item instances of each type (e.g. 9 cases, 13 posts) — already published, visible at `/cases` and `/blog`
- M taxonomy terms attached to the items
- K option groups configured (nav, contato, social, stats, footer)
- The site renders the original content immediately at `/`. Open it side-by-side with the original to confirm.

**Manual cleanup probably needed:**
- Original HTML files in `theme/` (kept for reference; user can delete after verifying templates work)
- Image fields hold path strings (`theme/assets/...`) — they render fine, but for proper resizing/cropping pipeline, upload via `/admin/media` and re-select inside each item
- Form recipients: configure in `/admin/forms/<id>` so submissions email someone. Without recipients, submissions are saved but don't email out
- Any `<script>` blocks for third-party widgets (analytics, chat, embed forms) — point them out so user wires them via theme settings or `tracking_*` helpers
- SEO meta fields are intentionally left empty — user fills `meta_title`, `meta_description`, `og_image` per page when they're ready

**Try it:**
- `./bin/ellev serve 8080` (if dev), or open the configured domain
- `/admin/login` to see all pages and items pre-filled with the migrated content

## Patterns to keep in mind

When extracting fields, think about WHY each piece of text/image would be editable:

- **Editable**: hero title, intro paragraph, CTA text, image, prices, dates, names that change per project
- **Hardcoded in template**: section labels ("Our Services", "Featured Posts"), navigation labels (those are option-driven), copyright year (use `<?= date('Y') ?>`), structural CSS class names

When ambiguous, lean toward **editable** — Ellev's admin handles empty fields gracefully (Ellev-style templates use `<?php if ($field !== ''): ?>` patterns), and giving the user one extra field to ignore is better than baking content into PHP they can't reach from the admin.

## Don't surprise the user

Never:
- Modify files outside `theme/` and the install dir without explicit confirmation
- Run destructive commands (`rm -rf`, `git reset`) without confirmation
- Delete the original HTML files automatically — leave them in `theme/` so the user can compare against the converted templates
- Generate fields the user didn't see in the plan (the plan IS the contract)
- Seed content the user didn't see in the plan — the "Pre-populated content" section IS the contract for what gets seeded
- Run `theme/install/seed.php` against an install that's not freshly synced — the idempotency guard protects re-runs, but if the user has already started editing in admin, ask before running
- Programmatically upload to the media library (`storage/uploads/`) — image fields use path strings, not generated media IDs. Don't bypass this without asking
- Publish items without `'status' => 'published'` set explicitly in the seed (so the user understands why archives suddenly show content)

If something goes sideways mid-execution (file write fails, schema:validate errors, seed errors out partway), STOP. Report what's done, what failed. Don't keep generating more files on a broken foundation. The seed's idempotency guard means a re-run after fixing won't double-write — it either picks up cleanly or skips entirely.
