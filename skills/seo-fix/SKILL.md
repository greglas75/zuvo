---
name: seo-fix
description: >
  Apply fixes from seo-audit findings. Reads audit JSON, classifies fixes by
  safety tier (SAFE/MODERATE/DANGEROUS), applies templates per framework.
  Supports Astro, Next.js, Hugo. Modes: default (SAFE only), --auto (SAFE+MODERATE),
  --all (all tiers, requires confirmation), --dry-run, --finding F1,F3,
  --fix-type sitemap-add,robots-fix,schema-cleanup.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # locate sitemap/robots/llms.txt/canonical
    - get_file_outline
    - search_text              # find existing meta tags before patching
    - search_symbols
    - get_symbol
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map, nextjs_metadata_audit]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:seo-fix — Apply SEO Audit Fixes

Read seo-audit JSON findings. Plan patches per finding. Validate each patch. Apply by safety tier. Verify build. Report.

**Scope:** Post-audit fix application for SEO findings.
**Out of scope:** Content writing, image generation, WordPress plugin config, React SPA fixes, redirects, noindex management, hreflang management. Out-of-scope content findings may still emit an advisory content scaffold.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup and update
4. `../../shared/includes/seo-fix-registry.md` -- Canonical fix_type, safety, eta, and manual verification rules
5. `../../shared/includes/fix-output-schema.md` -- JSON report contract
6. `../../shared/includes/seo-bot-registry.md` -- Canonical AI/search bot policy taxonomy for robots fixes
7. `../../shared/includes/run-logger.md` -- Run logging contract
8. `../../shared/includes/retrospective.md` -- Retrospective protocol
8. `../../shared/includes/verification-protocol.md` -- Fresh-evidence rules for build and endpoint verification
9. `../../shared/includes/knowledge-prime.md` -- Project knowledge priming
10. `../../shared/includes/knowledge-curate.md` -- Learning extraction after work

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md     -- [READ | MISSING -> STOP]
  2. env-compat.md         -- [READ | MISSING -> STOP]
  3. backlog-protocol.md   -- [READ | MISSING -> STOP]
  4. seo-fix-registry.md   -- [READ | MISSING -> STOP]
  5. fix-output-schema.md  -- [READ | MISSING -> STOP]
  6. seo-bot-registry.md   -- [READ | MISSING -> STOP]
  7. ../../shared/includes/run-logger.md -- [READ | MISSING -> STOP]
  8. ../../shared/includes/retrospective.md -- [READ | MISSING -> STOP]
  8. ../../shared/includes/verification-protocol.md -- [READ | MISSING -> STOP]
  9. ../../shared/includes/knowledge-prime.md  -- READ/MISSING
  10. ../../shared/includes/knowledge-curate.md -- READ/MISSING
  11. ../../shared/includes/no-pause-protocol.md -- READ/MISSING (HARD: no mid-batch pauses)
```

If any file is missing, STOP.

If native agent dispatch is unavailable, execute the workflow sequentially
yourself, preserve the same validation checkpoints, and note the fallback mode
in the final fix report.

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

Build verification claims follow `verification-protocol.md`:
- Capture stdout/stderr **and the process exit code**
- Treat `exit code != 0` as a build failure even if logs contain optimistic lines
  such as `Completed`, `Built`, or similar
- Only report `build_result: PASS` when the detected build exits with code `0`

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

### Knowledge Prime

Run the knowledge prime protocol from `knowledge-prime.md`:
```
WORK_TYPE = "implementation"
WORK_KEYWORDS = <keywords from user request>
WORK_FILES = <files being touched>
```

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
 AUDIT: seo-audit 2026-03-28 (2h ago) | Score: 53/100 (C) | 16 findings
  SAFE:              5 findings (auto-fixable)
  MODERATE:          5 findings (fixable with validation)
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

Read `../../shared/includes/seo-fix-registry.md` for the canonical:
- Template registry (fix_type → framework → target file priority)
- Safety classification (per framework, with context-aware upgrade rules)
- Fix parameters schema (required and optional params per fix_type)

Read `../../shared/includes/seo-bot-registry.md` when planning or
validating `robots-fix`. Read `../../shared/includes/fix-output-schema.md`
before writing the final JSON report.

The shared registry is the single source of truth. Do not override safety classifications locally.

**Template target priorities (framework-specific):**

The shared registry lists fix_types and safety. The TARGET FILE PRIORITY (which file to modify first) is skill-specific context that lives here:

| fix_type | astro target priority | nextjs target priority | hugo target priority |
|----------|-----------------------|------------------------|----------------------|
| `json-ld-add` | Existing layout `<head>` | Sitewide: `app/layout.tsx`. Page-level: specific `page.tsx` | `layouts/partials/json-ld.html` |
| `schema-cleanup` | Existing layout or page-level JSON-LD block with duplicate/spam evidence | Existing `app/layout.tsx` or conflicting page-level JSON-LD block | Existing partial or page template with duplicate JSON-LD evidence |
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
- `robots-fix`: if Cloudflare, WAF, CDN, or another edge/network provider is
  detected or strongly suspected, do not auto-claim success from a file-level
  patch alone. Escalate to `NEEDS_REVIEW` with `network_override_risk=true`.
  Generated policy must cover all canonical bot keys from
  `seo-bot-registry.md`, grouped by tier with explanatory comments:
  training defaults to `Disallow`, search/retrieval/user-proxy defaults to
  `Allow`, unless the source audit explicitly recommends a different conscious
  policy.
- `json-ld-add`: if existing schema is duplicated, spam-like, or already dense,
  reroute to `schema-cleanup` or `NEEDS_REVIEW` before adding more JSON-LD.
- `schema-cleanup`: exact duplicates may be cleaned automatically; conflicting
  non-identical blocks remain `NEEDS_REVIEW`.
- `meta-og-add`: normalize `og:type` by page class while preserving intentional
  page-specific overrides when evidence is clear.
- `sitemap-add`: if an existing sitemap has stale or uniform `lastmod` values,
  treat it as `NEEDS_REVIEW` instead of silently preserving a misleading sitemap.
- `headers-add`: use the baseline header set from the shared registry and prefer
  report-only CSP unless a stronger existing CSP is already present.
  Baseline means HSTS, `X-Content-Type-Options`, `Referrer-Policy`,
  `Permissions-Policy`, and `Content-Security-Policy-Report-Only` unless the
  target platform already exposes a stronger equivalent.

**`llms-txt-add` generation logic (two files + noindex header):**

1. **`llms.txt` (index):** Generate from project metadata:
   ```markdown
   # {site_name}
   > {one-line description from package.json or README first paragraph}

   ## Metadata
   - Last updated: {ISO date}
   - Language: {lang code from html lang attr or config}
   - Total pages: {count of indexed pages}

   ## Docs
   - [{title}]({path}): {first sentence of file}
   ```
   Sources for pages: `docs/*.md`, `content/**/*.md`, `README.md`, sitemap routes. Each entry = title + path + first meaningful sentence.

2. **`llms-full.txt` (aggregated content):** Concatenate actual content from existing files:
   - Scan: `README.md`, `docs/*.md`, `content/**/*.md`, `pages/**/*.md` (ordered by importance)
   - For each file: extract title (H1 or frontmatter title) + full markdown body
   - Join with `---` separator between sections
   - Prepend same header as llms.txt (`# {site_name}\n> {description}\n\n## Metadata\n...`)
   - If no content files found: skip llms-full.txt, note in report "No content files to aggregate for llms-full.txt"
   - Max size per file: **500KB** (truncate with "... [truncated, see full docs at {url}]")
   - **Size strategy by corpus:**
     - **< 100 pages (corpus < 500KB):** single `llms-full.txt`
     - **100–300 pages (500KB–2MB):** single `llms-full.txt` capped at 500KB,
       prioritize key content (homepage, landing pages, recent articles).
       Note excluded content in fix report.
     - **300+ pages (corpus > 2MB):** split into category files linked from
       `llms.txt` index (e.g. `llms-guides.txt`, `llms-blog.txt`,
       `llms-faq.txt`). Each capped at 500KB. Derive categories from site
       nav, content dirs, or CMS taxonomy.
     - Before splitting, compress: remove duplicate content, strip
       boilerplate (repeated headers/footers), keep summaries only for
       low-value pages (changelogs, legal), drop embedded code blocks from
       non-technical content.
   - Add `X-Robots-Tag: noindex` for all generated `llms*.txt` paths (step 4)

3. **Validation:** After generating:
   - Both files must be valid markdown (no broken syntax)
   - llms.txt links must point to paths that exist in the project
   - llms-full.txt must have substantive content (not just headers)
   - When a framework exposes a static asset directory (`public/` or
     `static/`), write both files there. Do **not** prefer a route file such as
     `src/pages/llms-full.txt.ts` when the static target exists.

4. **X-Robots-Tag: noindex (MANDATORY):** Prevent search engines from indexing
   llms*.txt while keeping them crawlable for AI bots:
   - Detect platform header config: `_headers` (Cloudflare/Netlify),
     `vercel.json` (Vercel), or existing host config
   - If `_headers` exists: append `X-Robots-Tag: noindex` rules for
     `/llms.txt`, `/llms-full.txt`, and any category files (`/llms-*.txt`)
   - If `_headers` does not exist AND `headers-add` is also being applied:
     include the rules in the new `_headers` file
   - If `_headers` does not exist AND no `headers-add`: create a minimal
     `_headers` with only the `X-Robots-Tag` rules
   - For Vercel: merge into `vercel.json` `headers` array
   - Do NOT use `robots.txt Disallow` — it blocks crawling but not indexing,
     and the URL can still appear in SERPs via external links
   - Record the header config file in `files_modified`

**Not in registry (manual only):**
- `hreflang-add`, `noindex-change`, `redirect-add` -- listed in shared registry as non-fixable

**Advisory content scaffold:**
- For out-of-scope content quality findings, seo-fix may emit a structured
  content scaffold instead of mutating content files:
  - suggested H2/H3 outline
  - target word-count band
  - answer-first opener template

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
   - For `headers-add`, preserve stronger existing policy and append only the
     missing baseline headers
   - If existing related content found → upgrade to MODERATE (context-aware safety)
3. **Apply:** Edit the file. One edit per file (batch if multiple findings target same file).
4. Record: `{ finding_id, action, file, status: "FIXED", eta_minutes, manual_checks, risk_notes, network_override_risk }`

### 2.2 MODERATE fixes (applied with 3-layer validation)

For each MODERATE finding:
1. **Plan:** Determine target file per priority list. Read target + surrounding context.
2. **Validate (3 layers):**
   - **File parse:** target file is syntactically valid (JSON, JSX, TOML, HTML)
   - **Framework convention:** fix follows framework idiom (e.g., Next.js uses Metadata API, not manual `<meta>` tags)
   - **Finding-specific check:**
    - Sitemap: `site` URL is configured in framework config
    - Sitemap: if an existing sitemap has stale `lastmod` values, downgrade to `NEEDS_REVIEW`
    - JSON-LD: schema properties match schema.org required fields for declared type and do not layer on top of duplicate/spam-like blocks
    - `schema-cleanup`: remove exact duplicates only; conflicting blocks or spam-like long descriptions stay `NEEDS_REVIEW`
    - Meta tags: image URLs are absolute (not relative), og:image dimensions noted, `og:type` matches page class
    - Robots.txt: Googlebot is NOT blocked after fix, AI policy is explicit for relevant bot keys, and Cloudflare/network overrides are surfaced as review risk
3. **Apply:** If all 3 layers pass, apply patch. If any layer fails: revert, mark `NEEDS_REVIEW`.
4. Record: `{ finding_id, action, file, status: "FIXED" | "NEEDS_REVIEW", validation_result, eta_minutes, manual_checks, risk_notes, network_override_risk }`

### 2.3 INSUFFICIENT DATA findings

Split into two categories:
- **Cannot confirm bug** (e.g., "HTTPS active" inconclusive in code-only):
  `INSUFFICIENT_DATA`. Cannot fix what is not confirmed broken.
- **Cannot determine params** (e.g., locale unknown but fix is otherwise safe):
  offer `--dry-run` suggestion with placeholder params. Mark as
  `NEEDS_PARAMS` with explicit manual checks.

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

Run the detected build command and record:
1. Exact command executed
2. Full exit code
3. Whether verification is build-only or build + artifact/endpoint checks

Hard rules:
- `build_result: PASS` requires `exit code = 0`
- `build_result: FAIL` for any non-zero exit code, even if the log contains
  success-looking markers
- For fixes that create or expose public artifacts/endpoints (`llms.txt`,
  `llms-full.txt`, `robots.txt`, `sitemap.xml`), do a post-build existence
  check. Prefer inspecting the built output directory; if that is not
  deterministically available, use a local preview/HTTP probe instead.
- If a built artifact is missing, empty, or the endpoint returns `404`, the
  action cannot stay `VERIFIED`

### 3.2 Rollback model

**Per-finding rollback** (not just "last fix"):
- Before each file modification, snapshot is saved (Phase 2.0)
- If build fails: identify which file(s) caused the failure
- Rollback that file to snapshot, re-run build
- If build passes but a required artifact/endpoint check fails (for example
  `/llms-full.txt` returns `404` or the built file is absent), rollback the
  related fix or downgrade it to `NEEDS_REVIEW` with `verification="FAILED"`
- If still failing: rollback all files from current batch, mark remaining findings as `NEEDS_REVIEW`
- If build passes after selective rollback: keep successful fixes, report rolled-back ones

### 3.3 Gate re-check

For each fix_type applied, run a targeted mini-check (not full cross-file audit):

| fix_type | Re-check |
|----------|----------|
| `llms-txt-add` | Confirm `llms.txt` exists at the static target, and if `llms-full.txt` was generated, verify the built artifact or local preview response for `/llms-full.txt` is non-empty and not `404`. Confirm `X-Robots-Tag: noindex` is configured in platform headers (`_headers`, `vercel.json`, or equivalent) for all `llms*.txt` paths |
| `sitemap-add` | Verify sitemap config exists in framework config (CG1 proxy) and note whether `lastmod` strategy still needs manual review |
| `json-ld-add` | Grep for `application/ld+json` in target file (CG5 proxy) and confirm raw-source visibility is plausible |
| `schema-cleanup` | Confirm duplicate schema blocks were reduced and no exact duplicates remain |
| `robots-fix` | Parse robots.txt, confirm Googlebot not blocked (CG2 proxy), and keep `network_override_risk=true` when Cloudflare or another edge layer may still override behavior |
| `meta-og-add` | Confirm `og:image` is absolute and `og:type` matches the resolved page class |
| `headers-add` | Confirm the baseline header set is present in the chosen host config |
| `canonical-fix` | Grep for `rel="canonical"` or `alternates.canonical` (CG4 proxy) |
| Others | Grep for injected content in target file |

Verification semantics:
- `VERIFIED`: build exited `0` (when a build exists) and the targeted re-check
  passed, including artifact/endpoint checks for generated public files
- `ESTIMATED`: source-level mutation looks correct, but no deterministic
  artifact/endpoint check was possible after a successful build
- `FAILED`: the re-check or artifact/endpoint check failed; do not leave the
  action reported as a clean success

### 3.4 Adversarial Review (MANDATORY — do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --mode code
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** — fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** — known concerns (max 3, one line each).

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this — if true, it's serious."

"Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, add it to backlog with file:line. The adversarial review found a real problem — don't dismiss it just because it existed before your changes.

---

## Phase 4: Report

### 4.1 Estimated score calculation

`estimated_after_score` is calculated by:
1. Take all findings from audit JSON
2. For findings confirmed FIXED: change status from FAIL to PASS
3. For findings with `NEEDS_REVIEW`, `MANUAL`, `OUT_OF_SCOPE`,
   `NO_TEMPLATE`, or `INSUFFICIENT_DATA`: keep original status
4. For `INSUFFICIENT DATA` findings: keep excluded
5. Recalculate dimension scores and overall using same weights as seo-audit Phase 4
6. Do NOT simulate benefits of unverified fixes

### 4.2 Report template

Estimated effort rubric: `EASY = <30min`, `MEDIUM = 1-4h`, `HARD = 1+ day`.

Report outputs must carry the expanded v1.1 semantics:
- `estimated_time` for each action or roll-up
- `manual_checks` for remaining platform validation
- `policy_notes` for strategy or platform caveats
- `advisory_scaffolds` for non-mutating content follow-up

```
SEO FIX REPORT -- [project name]
----
Findings: 16 total | 6 fixed | 2 needs review | 1 needs params | 1 manual | 2 out of scope | 1 no template | 1 insufficient data
Score:    53 -> 74 (estimated from confirmed fixes only)
Build:    [PASS | FAIL (rolled back N fixes) | NOT VERIFIED]
----

FIXED (auto-applied):
  F2: Added llms.txt + llms-full companion        public/llms.txt + public/llms-full.txt (new)  [VERIFIED] ~10 min
  F5: Added baseline security headers             public/_headers (new)        [VERIFIED] ~15 min
  F8: Added font-display: swap                    src/styles/global.css:14     [VERIFIED] ~5 min

FIXED (validated):
  F1: Added @astrojs/sitemap integration           astro.config.mjs:3,8         [VERIFIED] ~20 min
  F3: Added JSON-LD (WebSite + Organization)       src/layouts/Layout.astro:12  [VERIFIED] ~30 min
  F4: Cleaned duplicate Article schema             src/layouts/Layout.astro:18  [VERIFIED] ~35 min

NEEDS REVIEW:
  F5: robots.txt fix                               public/robots.txt
      Reason: Cloudflare or another edge layer may override robots.txt
      Manual checks: Dashboard AI bot controls, curl -A 'GPTBot' -I, curl -A 'Googlebot' -I
  F6: OG image meta                                src/layouts/Layout.astro
      Reason: og:image uses relative path or `og:type` does not match page class
  F9: Existing sitemap metadata                    public/sitemap.xml
      Reason: `lastmod` values are stale/uniform — review generation strategy before trusting the file
  F10: lang attribute                              src/layouts/Layout.astro
      Reason: locale not derivable from config — specify locale

NEEDS_PARAMS:
  F11: Locale-dependent sitemap target             astro.config.mjs
      Reason: `site_url` or locale mapping must be supplied before mutation

MANUAL (DANGEROUS — user action required):
  F12: Canonical URL configuration
      Risk: wrong canonical can deindex pages
      Suggested diff: [exact diff]

OUT OF SCOPE:
  F13: Content quality gap                         Requires human writing
  F14: E-E-A-T author information                  Requires real author data

ADVISORY CONTENT SCAFFOLD:
  F13: Suggested H2 outline, target word band, and answer-first opener template
      Reason: content scaffold is advisory only and does not mutate content files

NO TEMPLATE:
  F15: hreflang tags                               DANGEROUS — requires locale strategy

INSUFFICIENT DATA:
  F16: HTTPS verification                          Requires live audit

Run: <ISO-8601-Z>	seo-fix	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

NEXT STEPS:
  1. Review NEEDS_REVIEW items above
  2. Supply missing params for NEEDS PARAMS items, then rerun with `--fix-type` or `--finding`
  3. Apply MANUAL fixes if appropriate: zuvo:seo-fix --finding F12 --all
  4. Re-audit for exact score: zuvo:seo-audit
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use `N-fixes` (number of findings fixed).

---

### Knowledge Curation

After work is complete, run the knowledge curation protocol from `knowledge-curate.md`:
```
WORK_TYPE = "implementation"
CALLER = "zuvo:seo-fix"
REFERENCE = <git SHA or relevant identifier>
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

2. Save fix JSON to `audit-results/seo-fix-YYYY-MM-DD.json` (schema: `../../shared/includes/fix-output-schema.md`):

```json
{
  "version": "1.1",
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
      "verification": "VERIFIED",
      "eta_minutes": 20,
      "estimated_time": "<30 minutes",
      "manual_checks": null,
      "policy_notes": [
        "Keep sitemap host aligned with the canonical root"
      ],
      "advisory_scaffolds": null,
      "risk_notes": [],
      "network_override_risk": false
    }
  ],
  "manual_checks": [
    "Confirm edge-layer bot controls do not override file-level crawler policy"
  ],
  "estimated_time": {
    "easy": 1,
    "medium": 0,
    "hard": 0
  },
  "policy_notes": [
    "Training bots may remain blocked while user-proxy bots stay allowed"
  ],
  "advisory_scaffolds": [
    "Provide a human-written outline for thin content findings instead of auto-writing copy"
  ],
  "files_modified": ["astro.config.mjs", "src/layouts/Layout.astro", "public/llms.txt"],
  "build_result": "PASS"
}
```
