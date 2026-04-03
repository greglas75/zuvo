---
name: seo-fix
description: >
  Apply fixes from seo-audit findings. Reads audit JSON, classifies fixes by
  safety tier (SAFE/MODERATE/DANGEROUS), applies templates per framework.
  Supports Astro, Next.js, Hugo. Modes: default (SAFE only), --auto (SAFE+MODERATE),
  --all (all tiers, requires confirmation), --dry-run, --finding F1,F3, --fix-type sitemap-add.
---

# zuvo:seo-fix — Apply SEO Audit Fixes

Read seo-audit JSON findings. Plan patches per finding. Validate each patch. Apply by safety tier. Verify build. Report.

**Scope:** Post-audit fix application for SEO findings.
**Out of scope:** Content writing, image generation, WordPress plugin config, React SPA fixes, redirects, noindex management, hreflang management.

## Mandatory File Loading

Read these files before any work begins:

1. `{plugin_root}/shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `{plugin_root}/shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `{plugin_root}/shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup and update

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md     -- [READ | MISSING -> STOP]
  2. env-compat.md         -- [READ | MISSING -> STOP]
  3. backlog-protocol.md   -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- Write Scope

**Allowed write targets:**
- Files listed in template registry target paths (source/config files)
- `audit-results/` for the fix report (`.md` and `.json`)
- `memory/backlog.md` for backlog updates

**FORBIDDEN:**
- Installing packages without explicit user confirmation (e.g., `@astrojs/sitemap`). If a fix requires dependency installation, escalate to NEEDS_REVIEW with install instructions.
- Writing to files not referenced by template registry or finding evidence
- Deleting files

### GATE 2 -- DANGEROUS Fix Confirmation

DANGEROUS fixes (`canonical-fix`) are NEVER auto-applied. Procedure:
1. Show the exact diff that would be applied
2. Explain the risk and expected SEO impact
3. List target files
4. Wait for explicit positive confirmation from user
5. Without confirmation: mark as `MANUAL` and move to next finding

### GATE 3 -- Stale Audit Protection

If audit JSON `timestamp` is >24h old:
- `--dry-run` mode: proceed with warning
- Default mode (SAFE only): proceed with warning
- `--auto` or `--all` mode: **require user confirmation** before mutating. Without confirmation, fall back to `--dry-run`.

### GATE 4 -- Build Verification

After applying fixes, run build verification. Detect build command from project:
1. `package.json` scripts: `build`, `astro build`, `next build`
2. Hugo: `hugo` binary
3. If no build command found: skip build verification, note in report

Build failure → rollback (see Phase 3 rollback model).

### GATE 5 -- Dirty File Check

Before modifying any file, check for uncommitted changes in that file (`git diff --name-only`). If the file has uncommitted changes, mark finding as `NEEDS_REVIEW` instead of modifying.

---

## Arguments

| Argument | Behavior |
|----------|----------|
| (default) | Read latest JSON, apply SAFE fixes, recommend MODERATE + DANGEROUS |
| `--auto` | Apply SAFE + MODERATE fixes automatically (skip DANGEROUS) |
| `--all` | Apply all fixes including DANGEROUS (requires confirmation per fix) |
| `--dry-run` | Show what would be fixed, change nothing |
| `--finding D4-sitemap-exists,D3-json-ld-ssr` | Fix specific findings by stable ID (also accepts F1,F3 display IDs) |
| `--fix-type sitemap-add,json-ld-add` | Fix specific fix_type categories |
| `[json-path]` | Use specific JSON file instead of latest |

Note: `--fix-type` matches against `findings[].fix_type` field. For convenience aliases: `sitemap` = `sitemap-add`, `json-ld` = `json-ld-add`, `og` = `meta-og-add`, `robots` = `robots-fix`, `headers` = `headers-add`, `canonical` = `canonical-fix`.

---

## Phase 0: Load Findings

### 0.1 Locate audit JSON

1. If `[json-path]` provided: use that file
2. Otherwise: glob `audit-results/seo-audit-*.json`, parse `timestamp` from each, select most recent by timestamp (not filename)
3. If no JSON found: "No audit JSON found. Run `zuvo:seo-audit` first." STOP.

### 0.2 Validate schema and version

**Version handshake:** Check `version` field. Supported versions: `"1.0"`, `"1.1"` (minor bumps are backward compatible). If major version differs (e.g., `"2.0"`): STOP with "Unsupported audit schema version [X]. Update zuvo:seo-fix."

**Required fields.** If any missing, STOP with "Invalid audit JSON: missing field [X]":

```
Required: version, skill, timestamp, result, score.overall
Required array: findings[]
Required per finding: id, dimension, check, status, fix_type, fix_safety, fix_params
```

Note: `id` should be the stable finding ID (`{dimension}-{check}`, e.g., `D4-sitemap-exists`). Sequential display IDs (F1, F2) are also accepted but `--finding` filtering prefers stable IDs.

### 0.3 Check result and freshness

**PROVISIONAL audit handling:** If `result` = `"PROVISIONAL"` (audit has INSUFFICIENT DATA gates):
- Default mode and `--dry-run`: proceed normally, SAFE fixes are still safe regardless of incomplete gates
- `--auto` mode: restrict to SAFE fixes only (do not auto-apply MODERATE). Warn: "Audit is PROVISIONAL — restricting to SAFE fixes. Re-run seo-audit with --live-url for full coverage."
- `--all` mode: require confirmation per fix (same as DANGEROUS gate)

**Freshness check:**
Read `timestamp` field. Calculate age.
- If <=24h: proceed
- If >24h: apply GATE 3 (stale audit protection)

### 0.4 Print summary

```
AUDIT: seo-audit 2026-03-28 (2h ago) | Score: 53/100 (C) | 13 findings
  SAFE:              5 findings (auto-fixable)
  MODERATE:          4 findings (fixable with validation)
  DANGEROUS:         1 finding (manual only)
  OUT_OF_SCOPE:      2 findings (no template — content/E-E-A-T)
  NO_TEMPLATE:       1 finding (fix_type not in registry)
  INSUFFICIENT DATA: 1 finding (require live audit for verification)
```

---

## Phase 1: Detect Framework & Targets

### 1.1 Stack detection (self-contained)

Detect framework directly — do NOT depend on seo-audit Phase 0.2 at runtime:

```bash
# Inline stack detection (same logic as seo-audit, self-contained)
ASTRO=$(find . -maxdepth 3 -name "astro.config.*" 2>/dev/null | wc -l)
NEXT=$(find . -maxdepth 3 -name "next.config.*" 2>/dev/null | wc -l)
HUGO=$(find . -maxdepth 2 \( -name "hugo.toml" -o -name "hugo.yaml" \) 2>/dev/null | wc -l)
```

Cross-check with `stack` field in audit JSON. If mismatch: warn "Stack changed since audit. Consider re-running `zuvo:seo-audit`."

Detect output directory for static files:
- Astro/Next.js/React: `public/`
- Hugo: `static/`
- Unknown: search for `public/` or `static/`, default to `public/`

### 1.2 Fix Registry (shared contract)

Read `{plugin_root}/shared/includes/seo-fix-registry.md` for the canonical:
- Template registry (fix_type → framework → target file priority)
- Safety classification (per framework, with context-aware upgrade rules)
- Fix parameters schema (required and optional params per fix_type)

The shared registry is the single source of truth. Do not override safety classifications locally.

**Template target priorities (framework-specific):**

The shared registry lists fix_types and safety. The TARGET FILE PRIORITY (which file to modify first) is skill-specific context that lives here:

| fix_type | astro target priority | nextjs target priority | hugo target priority |
|----------|-----------------------|------------------------|----------------------|
| `json-ld-add` | Existing layout `<head>` | Sitewide: `app/layout.tsx`. Page-level: specific `page.tsx` | `layouts/partials/json-ld.html` |
| `meta-og-add` | Existing BaseHead/head component | 1. `generateMetadata()`. 2. `metadata` export. 3. `app/layout.tsx` | 1. `opengraph.html` partial. 2. `head.html` |
| `headers-add` | Cloudflare: `public/_headers`. Vercel: existing config first. Netlify: `_headers` or `netlify.toml` | Same, prefer existing mechanism | Same |
| `llms-txt-add` | `public/llms.txt` + `public/llms-full.txt` | `public/llms.txt` + `public/llms-full.txt` | `static/llms.txt` + `static/llms-full.txt` |

All other fix_types: target file is deterministic from framework (single obvious location per the shared registry).

**Additional seo-fix rules (not in shared registry):**
- Context-aware safety upgrade: if target file has existing related config, upgrade one tier (SAFE→MODERATE, MODERATE→DANGEROUS)
- Dependency-touching fixes (e.g., `sitemap-add` on Astro needs `@astrojs/sitemap`): classify as NEEDS_REVIEW regardless of base safety
- `lang-attr-add`: if locale not derivable → NEEDS_REVIEW (do not default to en)
- `alt-text-add`: only images with decorative signals (role="presentation", aria-hidden, class icon/decoration). Others → NEEDS_REVIEW
- `viewport-add`: dedup scan before adding. Never duplicate.

**`llms-txt-add` generation logic (two files):**

1. **`llms.txt` (index):** Generate from project metadata:
   ```markdown
   # {site_name}
   > {one-line description from package.json or README first paragraph}

   ## Docs
   - [{title}]({path}): {first sentence of file}
   ```
   Sources for pages: `docs/*.md`, `content/**/*.md`, `README.md`, sitemap routes. Each entry = title + path + first meaningful sentence.

2. **`llms-full.txt` (aggregated content):** Concatenate actual content from existing files:
   - Scan: `README.md`, `docs/*.md`, `content/**/*.md`, `pages/**/*.md` (ordered by importance)
   - For each file: extract title (H1 or frontmatter title) + full markdown body
   - Join with `---` separator between sections
   - Prepend same header as llms.txt (`# {site_name}\n> {description}`)
   - If no content files found: skip llms-full.txt, note in report "No content files to aggregate for llms-full.txt"
   - Max size: cap at 100KB (truncate with "... [truncated, see full docs at {url}]")

3. **Validation:** After generating:
   - Both files must be valid markdown (no broken syntax)
   - llms.txt links must point to paths that exist in the project
   - llms-full.txt must have substantive content (not just headers)

**Not in registry (manual only):**
- `hreflang-add`, `noindex-change`, `redirect-add` -- listed in shared registry as non-fixable

---

## Phase 2: Apply Fixes (plan → validate → apply)

For each finding, execute three stages: **plan the patch**, **validate the patch**, **apply the patch**. Group multiple fixes targeting the same file into a single batch edit.

### 2.0 Pre-flight per file

Before modifying any file:
1. Save a snapshot of the original content (in memory, for rollback)
2. Check GATE 5 (dirty file check)
3. If multiple findings target the same file: parse existing structure first, then batch all patches into one coherent edit

### 2.1 SAFE fixes (auto-applied)

For each SAFE finding:
1. **Plan:** Determine target file and insertion point per template registry priority
2. **Validate:**
   - File parse: target file is readable and has expected structure
   - Dedup: the fix content does not already exist in the file (e.g., viewport meta already present)
   - If existing related content found → upgrade to MODERATE (context-aware safety)
3. **Apply:** Edit the file. One edit per file (batch if multiple findings target same file).
4. Record: `{ finding_id, action, file, status: "FIXED" }`

### 2.2 MODERATE fixes (applied with 3-layer validation)

For each MODERATE finding:
1. **Plan:** Determine target file per priority list. Read target + surrounding context.
2. **Validate (3 layers):**
   - **File parse:** target file is syntactically valid (JSON, JSX, TOML, HTML)
   - **Framework convention:** fix follows framework idiom (e.g., Next.js uses Metadata API, not manual `<meta>` tags)
   - **Finding-specific check:**
     - Sitemap: `site` URL is configured in framework config
     - JSON-LD: schema properties match schema.org required fields for declared type
     - Meta tags: image URLs are absolute (not relative), og:image dimensions noted
     - Robots.txt: Googlebot is NOT blocked after fix (re-check CG2 logic)
3. **Apply:** If all 3 layers pass, apply patch. If any layer fails: revert, mark `NEEDS_REVIEW`.
4. Record: `{ finding_id, action, file, status: "FIXED" | "NEEDS_REVIEW", validation_result }`

### 2.3 INSUFFICIENT DATA findings

Split into two categories:
- **Cannot confirm bug** (e.g., "HTTPS active" inconclusive in code-only): SKIP. Cannot fix what is not confirmed broken.
- **Cannot determine params** (e.g., locale unknown but fix is otherwise safe): offer `--dry-run` suggestion with placeholder params. Mark as `NEEDS_PARAMS`.

### 2.4 DANGEROUS fixes (gated by GATE 2)

For each DANGEROUS finding:
1. **Plan:** Generate the exact diff that would be applied
2. **Present to user:**
   - Show diff
   - Explain specific risk (e.g., "Wrong canonical URL can deindex pages. A single misconfiguration caused 95% traffic loss in documented cases.")
   - List all target files
   - Show expected SEO impact if fix is correct
3. **Wait for confirmation:** positive response → apply with 3-layer validation. No response or negative → mark `MANUAL`, move to next finding.
4. Record: `{ finding_id, action, file, status: "FIXED" | "MANUAL", diff, risk }`

---

## Phase 3: Verify

### 3.1 Build verification

Detect project build command:
1. Check `package.json` scripts for `build`, or framework-specific: `astro build`, `next build`
2. Hugo: check for `hugo` binary
3. If no build command detected: skip, note "No build verification available" in report

Run detected build command.

### 3.2 Rollback model

**Per-finding rollback** (not just "last fix"):
- Before each file modification, snapshot is saved (Phase 2.0)
- If build fails: identify which file(s) caused the failure
- Rollback that file to snapshot, re-run build
- If still failing: rollback all files from current batch, mark remaining findings as `NEEDS_REVIEW`
- If build passes after selective rollback: keep successful fixes, report rolled-back ones

### 3.3 Gate re-check

For each fix_type applied, run a targeted mini-check (not full cross-file audit):

| fix_type | Re-check |
|----------|----------|
| `sitemap-add` | Verify sitemap config exists in framework config (CG1 proxy) |
| `json-ld-add` | Grep for `application/ld+json` in target file (CG5 proxy) |
| `robots-fix` | Parse robots.txt, confirm Googlebot not blocked (CG2 proxy) |
| `canonical-fix` | Grep for `rel="canonical"` or `alternates.canonical` (CG4 proxy) |
| Others | Grep for injected content in target file |

Mark re-checks as `VERIFIED` or `ESTIMATED` (if full runtime check not possible in code-only mode).

---

## Phase 4: Report

### 4.1 Estimated score calculation

`estimated_after_score` is calculated by:
1. Take all findings from audit JSON
2. For findings confirmed FIXED: change status from FAIL to PASS
3. For findings with NEEDS_REVIEW/MANUAL/SKIP: keep original status
4. For INSUFFICIENT DATA findings: keep excluded
5. Recalculate dimension scores and overall using same weights as seo-audit Phase 4
6. Do NOT simulate benefits of unverified fixes

### 4.2 Report template

```
SEO FIX REPORT -- [project name]
----
Findings: 13 total | 7 fixed | 2 needs review | 1 manual | 1 out of scope | 1 no template | 1 insufficient data
Score:    53 -> 74 (estimated from confirmed fixes only)
Build:    [PASS | FAIL (rolled back N fixes) | NOT VERIFIED]
----

FIXED (auto-applied):
  F2: Added llms.txt                              public/llms.txt (new)        [VERIFIED]
  F5: Added security headers                      public/_headers (new)        [VERIFIED]
  F8: Added font-display: swap                    src/styles/global.css:14     [VERIFIED]

FIXED (validated):
  F1: Added @astrojs/sitemap integration           astro.config.mjs:3,8        [VERIFIED]
  F3: Added JSON-LD (WebSite + Organization)       src/layouts/Layout.astro:12  [VERIFIED]

NEEDS REVIEW:
  F4: robots.txt fix                               public/robots.txt
      Reason: existing rules modified — verify Googlebot access
  F6: OG image meta                                src/layouts/Layout.astro
      Reason: og:image uses relative path — provide absolute URL
  F9: lang attribute                               src/layouts/Layout.astro
      Reason: locale not derivable from config — specify locale

MANUAL (DANGEROUS — user action required):
  F7: Canonical URL configuration
      Risk: wrong canonical can deindex pages
      Suggested diff: [exact diff]

OUT OF SCOPE:
  F12: Content quality < 300 words                 Requires human writing
  F13: E-E-A-T author information                  Requires real author data

NO TEMPLATE:
  F10: hreflang tags                               DANGEROUS — requires locale strategy

INSUFFICIENT DATA:
  F11: HTTPS verification                          Requires live audit

NEXT STEPS:
  1. Review NEEDS_REVIEW items above
  2. Apply MANUAL fixes if appropriate: zuvo:seo-fix --finding F7 --all
  3. Re-audit for exact score: zuvo:seo-audit
```

---

## Phase 5: Update Backlog

### 5.1 Backlog operations

Per `shared/includes/backlog-protocol.md`:

| Finding status | Backlog action |
|----------------|---------------|
| FIXED | Remove row by fingerprint |
| NEEDS_REVIEW | If exists: increment `Seen`. If new: add as OPEN |
| MANUAL | Add as OPEN if not present |
| OUT_OF_SCOPE | Add as OPEN with category `seo-manual` |
| NO_TEMPLATE | Add as OPEN with category `seo-manual` |
| INSUFFICIENT DATA | Do not add (unconfirmed issue) |

**Fingerprint format:** `{file}|{dimension}|{check}`

Same format as seo-audit backlog persistence. Uses the stable check ID from the finding (e.g., `sitemap-exists`, `json-ld-ssr`), NOT the fix_type. Example: `astro.config.mjs|D4|sitemap-exists`.

### 5.2 Save report

1. Save markdown report to `audit-results/seo-fix-YYYY-MM-DD.md`
   Auto-increment: `-2.md`, `-3.md` if same-day file exists.

2. Save fix JSON to `audit-results/seo-fix-YYYY-MM-DD.json` (schema: `{plugin_root}/shared/includes/fix-output-schema.md`):

```json
{
  "version": "1.0",
  "skill": "seo-fix",
  "timestamp": "[current ISO 8601]",
  "project": "[working directory]",
  "args": "[arguments]",
  "source_audit": "audit-results/seo-audit-2026-03-28.json",
  "result": "PARTIAL",
  "score": {
    "before": 53,
    "estimated_after": 74,
    "method": "confirmed-fixes-only"
  },
  "summary": {
    "total": 13,
    "fixed": 7,
    "needs_review": 2,
    "manual": 1,
    "out_of_scope": 1,
    "no_template": 1,
    "insufficient_data": 1
  },
  "actions": [
    {
      "finding_id": "D4-sitemap-exists",
      "fix_type": "sitemap-add",
      "status": "FIXED",
      "file": "astro.config.mjs",
      "verification": "VERIFIED"
    }
  ],
  "files_modified": ["astro.config.mjs", "src/layouts/Layout.astro", "public/llms.txt"],
  "build_result": "PASS"
}
```

---

## Run Log

Log this run to `~/.zuvo/runs.log` per `{plugin_root}/shared/includes/run-logger.md`:
- SKILL: `seo-fix`
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: PASS/WARN/FAIL from fix results
- TASKS: number of fixes applied
- DURATION: `-`
- NOTES: fix summary (max 80 chars)
