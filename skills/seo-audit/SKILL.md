---
name: seo-audit
description: >
  SEO/GEO site audit covering 13 dimensions with 6 critical gates. Scans source
  code, templates, and config files across meta tags, structured
  data, AI crawlers, content quality, GEO readiness, performance, and optional
  live Core Web Vitals. Framework-aware: Astro, Next.js, Hugo, WordPress, React,
  plain HTML. Flags: full (default), [path], --live-url <url>, --quick,
  --content-only, --geo, --profile <marketing|docs|blog|ecommerce|app-shell>,
  --content-profile auto|marketing|docs|blog|ecommerce|app-shell,
  --live-sample-bots <default|all|bot1,bot2>, --persist-backlog.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # find sitemap.xml, robots.txt, rss.xml, /pages/
    - get_file_outline
    - search_text              # meta tags, JSON-LD, OpenGraph, canonical, llms.txt
    - search_symbols
    - search_patterns          # SEO anti-patterns (missing meta, malformed schema)
    - audit_scan
    - scan_secrets
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map, nextjs_metadata_audit]   # +1 SEO ext: metadata gaps
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_image_audit]
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

# zuvo:seo-audit — SEO/GEO Site Audit

Hybrid code-level and optional live site audit for search engine optimization and generative engine optimization. Examines source code, templates, and config files across 13 dimensions. Optional live mode adds Core Web Vitals measurement, broken link detection, and rendered DOM verification.

**Scope:** Pre-launch readiness, periodic SEO health, GEO optimization, content scaling preparation, post-redesign verification.
**Out of scope:** Code quality (`zuvo:code-audit`), security vulnerabilities (`zuvo:security-audit`), deep performance profiling (`zuvo:performance-audit`).

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/seo-bot-registry.md` -- Canonical AI/search bot taxonomy and live-probe scope
4. `../../shared/includes/seo-page-profile-registry.md` -- Profile-aware D9/D10 thresholds and downgrades
5. `../../shared/includes/seo-fix-registry.md` -- Canonical fix_type, safety, params (before Phase 6.2 JSON output)
6. `../../shared/includes/audit-output-schema.md` -- JSON output contract (before Phase 6.2)
7. `../../shared/includes/seo-check-registry.md` -- Canonical check slugs and enforcement layers (agents MUST use)
8. `../../shared/includes/run-logger.md` -- Run logging contract
9. `../../shared/includes/retrospective.md` -- Retrospective protocol

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md     -- [READ | MISSING -> STOP]
  2. env-compat.md         -- [READ | MISSING -> STOP]
  3. seo-bot-registry.md   -- [READ | MISSING -> STOP]
  4. seo-page-profile-registry.md -- [READ | MISSING -> STOP]
  5. seo-fix-registry.md   -- [READ | MISSING -> STOP]
  6. audit-output-schema.md -- [READ | MISSING -> STOP]
  7. seo-check-registry.md  -- [READ | MISSING -> STOP]
  8. run-logger.md           -- [READ | MISSING -> STOP]
  9. retrospective.md           -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift for structured data discovery, meta tag pattern search, and component analysis when available. Fall back to Grep/Read/Glob if unavailable.

---

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- Live Audit Consent

Read `../../shared/includes/live-probe-protocol.md` for the full consent gate,
rate limiting rules, error escalation thresholds, and HTTP method restrictions.
All live probing in this skill follows that shared protocol.

### GATE 2 -- Read-Only Audit

This audit is read-only against source code.

**Allowed write targets:**
- `audit-results/` for the report file (`.md` and `.json`)
- `memory/backlog.md` only when `--persist-backlog` is explicitly enabled

**FORBIDDEN:**
- Writing to any source/production file
- Modifying application code (suggest fixes in report, do not apply)
- Installing packages or modifying dependencies

---

## Phase 0: Parse $ARGUMENTS and Stack Detection

### 0.1 Arguments

| Argument | Behavior |
|----------|----------|
| `full` (default) | All 13 dimensions, code-only |
| `[path]` | Audit specific directory or module |
| `--live-url <url>` | Code audit + live audit (CWV, broken links, rendered DOM) |
| `--quick` | Critical gates only -- fast pass/fail (CG1-CG6) |
| `--content-only` | Content-focused audit: D7, D9, D10 |
| `--geo` | GEO-focused audit: D3, D5, D9, D10 |
| `--profile <marketing|docs|blog|ecommerce|app-shell>` | Canonical flag for overriding the D9/D10 content heuristics profile |
| `--content-profile auto|marketing|docs|blog|ecommerce|app-shell` | Legacy alias for `--profile`; accept for backward compatibility |
| `--live-sample-bots <default|all|bot1,bot2>` | In live mode, probe representative bots or an explicit subset from `seo-bot-registry.md` and emit a Bot Policy Matrix |
| `--persist-backlog` | Persist prioritized findings to `memory/backlog.md` |

Default: `full` (no `--live-url`).

### 0.2 Stack Detection

Detect the web framework from project config files:

```bash
# Portable web framework detection (BSD/GNU compatible)
ASTRO=$(find . -maxdepth 3 -name "astro.config.*" 2>/dev/null | wc -l)
NEXT=$(find . -maxdepth 3 -name "next.config.*" 2>/dev/null | wc -l)
HUGO=$(find . -maxdepth 2 \( -name "hugo.toml" -o -name "hugo.yaml" \) 2>/dev/null | wc -l)
WP=$(find . -maxdepth 3 -name "wp-config.php" 2>/dev/null | wc -l)
REACT=$(rg -l "from ['\"]react['\"]" . -g '*.tsx' -g '*.jsx' 2>/dev/null | head -5 | wc -l || grep -rl "from 'react'" . --include="*.tsx" --include="*.jsx" 2>/dev/null | head -5 | wc -l || true)
```

Also detect (with heuristics):

**Content format:**
- `markdown` — directories named `content/`, `posts/`, `blog/`, `pages/` containing `*.md` or `*.mdx`
- `database` — WordPress detected, or CMS config found (e.g., `strapi`, `payload`, `sanity`)
- `none` — no content directories found

**SEO files:**
- `robots.txt` — check `public/robots.txt`, `static/robots.txt`, or framework route (`src/pages/robots.txt.ts`, `app/robots.ts`)
- `sitemap` — check `public/sitemap*.xml`, framework config (`@astrojs/sitemap` in config, `app/sitemap.ts`), or generated output
- `llms.txt` — check `public/llms.txt`
- `llms-full.txt` — check `public/llms-full.txt` or framework-equivalent static output

**Deploy platform:**
- `vercel.json` or `.vercel/` → Vercel
- `netlify.toml` or `_headers` + `_redirects` → Netlify
- `wrangler.toml` or `_worker.js` → Cloudflare
- `.htaccess` → Apache
- `nginx.conf` or `/etc/nginx/` refs → Nginx
- None detected → Unknown

Store results:
```
DETECTED_STACK = [astro | nextjs | hugo | wordpress | react | html]
CONTENT_FORMAT = [markdown | database | none]
CONTENT_PROFILE = [auto | marketing | docs | blog | ecommerce | app-shell]
```

Print:
```
Stack: [framework] | Content: [format] | Profile: [profile] | Deploy: [platform]
SEO files: robots.txt [found/MISSING] | sitemap [found/MISSING] | llms.txt [found/MISSING] | llms-full.txt [found/MISSING]
Mode: [full/quick/content-only/geo] | Live: [url or "code-only"]
```

---

## Phase 1: MCP Tool Inventory (live mode only)

**Skip if no `--live-url`.** Code agents use only Grep/Read/Glob/Bash.

When `--live-url` is provided, check for browser tools:

```
Check 1: chrome-devtools OR playwright   -> DOM inspection, screenshots
Check 2: lighthouse (optional)           -> CWV measurement
Check 3: accessibility-scanner (optional) -> WCAG audit
```

For each missing tool that is relevant, inform the user of the capability gap and suggest installation.

**CWV fallback chain:**
1. chrome-devtools evaluate_script -> Performance API
2. Bash: `npx lighthouse <url> --output json --chrome-flags="--headless"`
3. SKIP: "No CWV measurement tools available. D8-live = INSUFFICIENT DATA."

Set availability flags and proceed.

If `--live-sample-bots` is set:
- `default` = probe one bot per class (`training`, `search`/`retrieval`,
  `user-proxy`) using `seo-bot-registry.md`
- `all` = probe every `live_test=yes` bot from the registry
- `bot1,bot2` = only probe canonical `bot_key` values explicitly listed by the
  user

---

## Phase 2: Code Audit (Parallel Agent Dispatch)

Dispatch 3 agents in parallel. Each agent evaluates its assigned dimensions independently.

### Dimension grouping

| Group | Agent | Dimensions | Shared data |
|-------|-------|-----------|-------------|
| A (Technical) | `agents/seo-technical.md` | D1, D4, D5, D11, D12, D13 | Config files, robots.txt, head templates |
| B (Content) | `agents/seo-content.md` | D7, D9, D10 | Content files, markdown/HTML pages |
| C (Assets) | `agents/seo-assets.md` | D2, D3, D6, D8 | Layout templates, asset files, build config |

### Mode-aware dimension filtering

Based on the mode from Phase 0, determine which agents to dispatch:

| Mode | Agents dispatched | Dimensions active |
|------|-------------------|-------------------|
| `full` (default) | All 3 | D1-D13 |
| `--quick` | Technical + Assets | Blocking gates only (CG1-CG6), no non-blocking dimension scoring |
| `--content-only` | Content only | D7, D9, D10 |
| `--geo` | Technical + Content + Assets | D3, D5, D9, D10 |

Pass `mode`, `selected_dimensions`, and `content_profile` to each dispatched
agent as input parameters. Agents MUST skip dimensions not in their
`selected_dimensions` list.

### Agent dispatch

Refer to `../../shared/includes/env-compat.md` for dispatch patterns per environment.

**Claude Code:** Use the Task tool to run all three in parallel:

```
Agent 1: SEO Technical (Group A)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/seo-technical.md
  input: detected_stack, [config file paths from Phase 0], codesift_repo, mode, selected_dimensions, content_profile

Agent 2: SEO Content (Group B)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/seo-content.md
  input: detected_stack, [content directory paths], codesift_repo, mode, selected_dimensions, content_profile

Agent 3: SEO Assets (Group C)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/seo-assets.md
  input: detected_stack, [layout/template paths], codesift_repo, mode, selected_dimensions, content_profile
```

<!-- PLATFORM:CODEX -->
**Codex:** Define TOML agents per env-compat.md patterns. Each agent runs in read-only sandbox.
<!-- /PLATFORM:CODEX -->

<!-- PLATFORM:CURSOR -->
**Cursor:** No agent dispatch. Execute each agent's analysis sequentially yourself, maintaining identical output format.
<!-- /PLATFORM:CURSOR -->

If native agent dispatch is unavailable, run the three agent analyses
sequentially yourself, preserve the same report sections, and note the fallback
mode in the final audit header.

### Waiting for results

Collect all 3 agent reports before proceeding to Phase 3 (live audit) or Phase 4 (scoring).

If an agent fails or times out:
- Retry once with same inputs
- If retry fails: log the error, proceed with results from successful agents, note the gap in the report

### Merge logic (before Phase 4)

After all agents complete:
1. Concatenate findings arrays from all 3 agents
2. Assign stable finding IDs using format `{dimension}-{check}` (e.g., `D4-sitemap-exists`, `D3-json-ld-ssr`). These IDs are deterministic across runs for the same codebase — unlike sequential F1/F2 which shift when findings change. Also assign display-order numbers (F1, F2, ...) for human-readable reports, but `--finding` filtering in seo-fix uses the stable ID.
3. Each agent returns raw check statuses per dimension -- main agent calculates numeric scores in Phase 4
4. Evaluate critical gates: CG1-CG4, CG6 from blocking Technical checks; CG5 from blocking Assets checks
5. If any dimension is missing (agent failed): mark as "INSUFFICIENT DATA" in scoring

**Agent vs main scoring boundary:** Agents return raw check statuses (PASS/PARTIAL/FAIL/INSUFFICIENT DATA) per check. The main agent calculates all numeric scores in Phase 4 using the status-to-value mapping. Agents do NOT calculate dimension scores themselves.

### Dimension constraints (normative -- agents MUST follow)

#### Enforcement model (normative)

Read `../../shared/includes/seo-check-registry.md` as the single source of truth
for `owner_agent`, `layer`, `enforcement`, and `evidence_mode`.

- `blocking`: can produce overall `FAIL` or `PROVISIONAL`
- `scored`: affects dimension and overall scores, but cannot alone flip the
  overall result
- `advisory`: prioritized and reported, but excluded from pass/fail logic

Only `blocking` checks may produce overall `FAIL` or `PROVISIONAL`. Heuristic,
advisory, or content-inaccessible findings must never create a blocking result
without direct evidence.

For fix_type identifiers and safety classifications, agents MUST use `../../shared/includes/seo-fix-registry.md` as the canonical source.

**D5 — AI crawler policy:**
- Use `../../shared/includes/seo-bot-registry.md` for the canonical live sample
  order and class semantics
- "Conscious decision" = explicit, non-contradictory policy for relevant bots or
  bot classes, with evidence that policy is intentional rather than accidental
- Deep robots analysis must look for problematic rules such as `/*.js*`,
  `/*.pdf$`, and `/*.feed*`
- When code suggests Cloudflare, WAF, CDN, or host-layer overrides, the result
  may be `PROVISIONAL` or `INSUFFICIENT DATA` until live probing confirms policy
- llms.txt in D5: check **presence and crawler accessibility only** (is it
  served? is it blocked?)

**D7 — Internal linking (code-only caveat):**
- In code-only mode, orphan detection is limited to static analysis (route files without inbound `<a>` or `<Link>` references). Report as "potential orphan risk", not definitive orphan.
- Full orphan confirmation requires live crawl or route graph analysis (--live-url mode).

**D9 — Content quality (measurable heuristics):**
- Use `../../shared/includes/seo-page-profile-registry.md` as the D9 default
  contract
- Thin-content thresholds are profile-aware, not globally fixed at 300 words
- If content is CMS-backed or inaccessible from the repo, downgrade to
  `advisory`, `N/A`, or `INSUFFICIENT DATA`, not hard failure
- Answer-first and chunkability must follow the active profile rather than a
  universal requirement

**D10 — GEO/AI readiness:**
- llms.txt in D10: evaluate **content quality and structure** (not presence —
  that's D5)
- Separate llms proposal compliance from best-practice richness:
  `llms.txt` presence/access belongs to D5, while `llms-full.txt` quality and
  companion richness belong to D10
- E-E-A-T signals: check for `author`, `datePublished`, `dateModified` fields in frontmatter/schema, plus citation/source references
- Freshness is heuristic and should remain `advisory` unless direct blocking
  evidence exists elsewhere

**D13 — Monitoring (advisory checks):**
- "Search Console setup indicators" is advisory only — cannot be confirmed from repo in most cases. Score as INSUFFICIENT DATA in code-only mode unless verification meta tag or DNS TXT record is present in config.

**D11 — Security and Technical (CG3 + CG4):**
- CG3 (HTTPS active): In code-only mode, report INSUFFICIENT DATA unless deploy config explicitly proves TLS (e.g., `vercel.json` with forceSSL, `netlify.toml` with force_ssl, Cloudflare always-HTTPS). Absence of `http://` refs is not proof of HTTPS.
- CG4 (Canonical present): Check for `<link rel="canonical">` or framework equivalent (Next.js `alternates.canonical`, Astro canonical in layout) at layout/template level. Must be a real check with evidence, not inferred from "no canonical issues found".

### CodeSift query patterns (when available)

Use these specific queries for SEO-relevant searches:

```
search_text(repo, "canonical", file_pattern="*.{astro,tsx,html,php}")
search_text(repo, "application/ld+json", file_pattern="*.{astro,tsx,html}")
search_text(repo, "og:image", file_pattern="*.{astro,tsx,html}")
search_text(repo, "robots", file_pattern="*.{txt,ts,js,toml,yaml}")
search_text(repo, "sitemap", file_pattern="*.{ts,js,mjs,toml,yaml}")
search_text(repo, "hreflang", file_pattern="*.{astro,tsx,html}")
search_text(repo, "noindex", file_pattern="*.{astro,tsx,html,ts}")
search_text(repo, "font-display", file_pattern="*.css")
search_text(repo, "llms.txt")
```

For framework-specific deep analysis, see agent instruction files which contain per-framework search patterns (Next.js Metadata API, Astro frontmatter, Hugo partials, WordPress hooks).

---

## Phase 3: Live Audit (only if --live-url)

**Runs in parallel with Phase 2 code agents in environments that support it.**

### 3.1 Core Web Vitals

Measure LCP, CLS, and INP using the available tool chain. Record measurement source (Lighthouse, Performance API, or N/A).

### 3.2 Source and Rendered Verification

Verify JSON-LD and meta tags in both:
1. **Initial HTML source / raw response body** -- fetch without JS execution (curl or equivalent). This is the SSR proof for CG5.
2. **Rendered DOM after page execution** -- confirms tags are visible post-hydration.

**Rendered DOM alone is NOT sufficient evidence for CG5.** JSON-LD injected client-side only after hydration = CG5 FAIL.

Also check that meta tags are rendered correctly and OG images are accessible.

### 3.3 Live Bot Matrix Sampling

When `--live-sample-bots` is provided, or when live mode already has enough
coverage to test representative bots safely, sample up to N bots from
`seo-bot-registry.md` using HEAD/GET requests with spoofed user-agents.

For each sampled bot, record:
- bot key and class
- verification mode (`source`, `live`, `merged`)
- response status code
- whether robots policy and live behavior agree
- any Cloudflare / WAF / CDN override suspicion

If live bot probing is unavailable, emit a Bot Policy Matrix from source-only
evidence and mark live-dependent rows as `PROVISIONAL`.

### 3.4 Broken Link Check

Check up to 50 internal links and 100 external links. Record status codes.

### 3.5 Visual Verification

If browser tools available, capture screenshots at 3 breakpoints (1440, 768, 375). Check for mobile rendering issues.

---

## Phase 4: Scoring

### 4.1 Evaluate Critical Gates

All 6 gates MUST have explicit status:

```
CG1: Sitemap exists                    -- from D4
CG2: Googlebot not blocked             -- from D5
CG3: HTTPS active                      -- from D11 (code-only: INSUFFICIENT DATA unless deploy config like `vercel.json`, `netlify.toml`, or force-https proves TLS)
CG4: Canonical tags present            -- from D11
CG5: JSON-LD server-side rendered      -- from D3
CG6: AI crawler policy conscious       -- from D5
```

**Critical gate statuses:**
- `PASS` -- evidence confirms gate is satisfied
- `FAIL` -- evidence confirms gate is not satisfied
- `INSUFFICIENT DATA` -- static analysis is inconclusive and no live verification is available

**Scoring rules:**
- Any blocking critical gate = `FAIL` -> overall result = `FAIL` regardless of score
- Any blocking critical gate = `INSUFFICIENT DATA` -> overall result = `PROVISIONAL` until live/source verification is completed
- `PROVISIONAL` does not block CI gates (it is not a FAIL) but flags incomplete assurance
- Only `blocking` checks and critical gates control `FAIL` vs `PROVISIONAL`.
  `scored` and `advisory` findings may lower scores, but they never override the
  overall result on their own.

### 4.2 Dimension Scores

**Check status → numeric value:**

| Status | Value | Notes |
|--------|-------|-------|
| PASS | 1.0 | Evidence confirms check passes |
| PARTIAL | 0.5 | Partially satisfied or minor issues |
| FAIL | 0.0 | Evidence confirms check fails |
| INSUFFICIENT DATA | excluded | Not counted in denominator |

Per-dimension: `score = (sum of check values / count of non-excluded checks) * 100`

**N/A rules per dimension (exclude from overall score):**

| Dimension | N/A when |
|-----------|----------|
| D6 (Images) | No `<img>` elements in codebase |
| D7 (Internal Linking) | Single-page site (no subpages) |
| D12 (Internationalization) | Single-language site (no hreflang, no i18n config) |
| D13 (Monitoring) | Static export with no analytics config — mark as advisory |
| D9 (Content Quality) | No content corpus (no markdown/blog/pages directories) |

### 4.3 Overall Score

```
Dimension weights:
  D1: 10%  D2: 5%   D3: 12%  D4: 8%   D5: 8%   D6: 5%   D7: 7%
  D8: 10%  D9: 15%  D10: 10% D11: 5%  D12: 3%  D13: 2%

Active weights = sum of weights where dimension is NOT N/A
Overall = sum(dimension_score * weight) / active_weights * 100
```

### 4.4 Sub-Scores

Each normalized to 0-100:
```
SEO Score:  D1 + D2 + D4 + D6 + D7 + D8 + D11 + D12 (weighted)
GEO Score:  D3 + D5 + D9 + D10 (weighted)
Tech Score: D4 + D8 + D11 + D12 + D13 (weighted)
```

### 4.5 Grade Assignment

```
A (>= 85): Production-ready SEO+GEO. Strong across all dimensions.
B (70-84): Good foundation. Optimization opportunities identified.
C (50-69): Significant gaps. Prioritized fixes needed before scaling.
D (< 50):  Major issues. SEO/GEO blocking growth.

Result overrides:
- Any blocking critical gate = FAIL -> result = "FAIL" (regardless of tier)
- Any blocking critical gate = INSUFFICIENT DATA -> result = "PROVISIONAL"
Tier is always calculated from score: A/B/C/D.
```

---

## Phase 5: Report Validation

Before generating the report, verify:

1. **Count Consistency:** Total checks = sum of all dimension checks. No check counted twice.
2. **Score Math:** Recalculate overall from dimension scores * weights. Must match within 0.1.
3. **Critical Gate Completeness:** All 6 gates have explicit PASS/FAIL/INSUFFICIENT DATA with evidence.
4. **Evidence Completeness:** Every FAIL finding has file:line or INSUFFICIENT DATA note.
5. **Priority Math:** Verify 3D priority calculation `(SEO * 0.4) + (Business * 0.4) + ((4 - Effort) * 0.2)`.
6. **Finding Numbering:** F-IDs are sequential (F1, F2, ...) with no gaps or duplicates.
7. **Summary Consistency:** findings_count in executive summary matches actual finding count in report body.
8. **Blocking Semantics:** Only checks marked `blocking` in `seo-check-registry.md` are allowed to create overall `FAIL` or `PROVISIONAL`.

Fix any discrepancies before presenting to user.

---

## Phase 6: Report

### Executive Summary

```
SEO/GEO AUDIT -- [project name]
----
SEO:     [N]/100  [HEALTHY / NEEDS ATTENTION / AT RISK / CRITICAL]
GEO:     [N]/100  [same scale]
Tech:    [N]/100  [same scale]
----
```

Health scale: HEALTHY (80+), NEEDS ATTENTION (60-79), AT RISK (40-59), CRITICAL (<40).

### Full Report Sections

1. **Header** -- project, date, stack, mode (code / code+live), content profile
2. **Critical Gates** -- 6 gates, PASS/FAIL/INSUFFICIENT DATA with evidence
3. **Dimension Scores** -- D1-D13 table with score, weight, weighted contribution
4. **Overall Score + Tier**
5. **Sub-Scores** -- SEO, GEO, Tech (each /100)
6. **Strengths** -- explicit PASS findings worth preserving
7. **Bot Policy Matrix** -- source/live/merged bot evidence with per-bot status
8. **Source vs Render Diff** -- raw response vs rendered DOM mismatches for JSON-LD and meta tags
9. **Quick Wins** -- findings with Priority >= 2.0 AND Effort = EASY
10. **Full Execution Plan** -- all findings sorted by priority descending
11. **Content Table** -- per-page/content-type coverage, word counts, answer-first rate (if content scanned)
12. **GEO Readiness Panel** -- 7 dimensions (llms.txt, AI crawlers, chunkability, structured HTML, citation readiness, E-E-A-T, freshness)
13. **Fix Coverage Summary** -- safe/moderate/dangerous/no-template counts from the shared fix registry
14. **Manual Check Recommendations** -- informational only, not scored
15. **CI-Parseable Summary** -- `SEO-AUDIT-RESULT: PASS|FAIL|PROVISIONAL score=NN tier=X critical=none|CG-N`

### Finding Format (stable across runs)

Every finding in the execution plan uses this structure:

```
[F-ID] [Dimension] [Severity] [Confidence]
  Issue: [one-line description]
  Evidence: [file:line or "code-only inference"]
  Why it matters: [SEO/GEO/business impact in one sentence]
  Fix: [actionable instruction]
  Priority: [N.N] (SEO=[1-3] × Biz=[1-3] × Effort=[1-3])
  Enforcement: [blocking | scored | advisory]
  Layer: [core | hygiene | geo | visibility-deferred]
  ETA: [minutes or "n/a"]

Confidence scale:
  HIGH   = direct source evidence (file:line confirms the finding)
  MEDIUM = inferred from config or indirect signals
  LOW    = heuristic or absence-based (e.g., file not found)
See also `../../shared/includes/seo-fix-registry.md` for the canonical confidence definitions.
```

### 3D Priority Calculation

For each finding:
```
SEO Impact:      HIGH(3) / MEDIUM(2) / LOW(1)
Business Impact: HIGH(3) / MEDIUM(2) / LOW(1)
Fix Effort:      EASY(1) / MEDIUM(2) / HARD(3)

Priority = (SEO * 0.4) + (Business * 0.4) + ((4 - Effort) * 0.2)
Range: 1.0 - 3.0

Quick Win = Priority >= 2.0 AND Effort = EASY
```

**Assignment rubric (to ensure consistent scoring):**

| Factor | 3 (HIGH) | 2 (MEDIUM) | 1 (LOW) |
|--------|----------|------------|---------|
| SEO Impact | Blocks indexation, rich results, or crawlability (CG fail) | Degrades ranking signals or social sharing | Cosmetic or minor optimization |
| Business Impact | Affects homepage, landing pages, or money pages | Affects secondary pages or non-revenue content | Affects low-traffic or internal pages |
| Fix Effort | 1-2 files, config change or additive insert | 3-5 files, template modification, testing needed | 6+ files, architecture change, or content creation |

### Save Report

```bash
mkdir -p audit-results
```

Save to: `audit-results/seo-audit-YYYY-MM-DD.md`

Auto-increment if a report for today already exists: `seo-audit-YYYY-MM-DD-2.md`, `seo-audit-YYYY-MM-DD-3.md`, etc.

### Phase 6.2: JSON Output

Before generating JSON, read `../../shared/includes/audit-output-schema.md` for the schema contract. For `fix_type` values and safety classifications, reference `../../shared/includes/seo-fix-registry.md`.

After saving the markdown report, also save structured JSON findings for downstream consumption by `zuvo:seo-fix` and CI pipelines.

**File:** `audit-results/seo-audit-YYYY-MM-DD.json`

Auto-increment with `-N` suffix if same-day file exists (same convention as `.md`).

**Schema:** See `../../shared/includes/audit-output-schema.md` for the full schema definition.

Serialize from Phase 4 scoring results:

```json
{
  "version": "1.1",
  "skill": "seo-audit",
  "timestamp": "[current ISO 8601]",
  "project": "[working directory absolute path]",
  "args": "[arguments from Phase 0]",
  "stack": "[detected stack from Phase 0]",
  "result": "[PASS, FAIL, or PROVISIONAL from critical gate evaluation]",
  "score": {
    "overall": [0-100],
    "tier": "[A/B/C/D]",
    "sub_scores": {
      "seo": [0-100],
      "geo": [0-100],
      "tech": [0-100]
    }
  },
  "critical_gates": [
    { "id": "CG1", "name": "Sitemap exists", "status": "PASS|FAIL", "evidence": "..." },
    { "id": "CG3", "name": "HTTPS active", "status": "INSUFFICIENT DATA", "evidence": "Code-only mode, cannot verify HTTPS" }
  ],
  "findings": [
    {
      "id": "D4-sitemap-exists",
      "display_id": "F1",
      "dimension": "D4",
      "check": "sitemap-exists",
      "status": "FAIL",
      "severity": "HIGH",
      "enforcement": "blocking",
      "layer": "core",
      "seo_impact": 3,
      "business_impact": 3,
      "effort": 1,
      "priority": 2.8,
      "confidence_reason": "No sitemap config or generated sitemap found in source tree",
      "evidence": "...",
      "file": null,
      "line": null,
      "fix_type": "sitemap-add",
      "fix_safety": "MODERATE",
      "fix_params": { "framework": "astro", "site_url": "https://example.com" },
      "eta_minutes": 15,
      "bot_scope": null
    }
  ],
  "bot_matrix": [
    {
      "bot_key": "gptbot",
      "status": "BLOCKED",
      "evidence": "public/robots.txt:12",
      "verification_mode": "code"
    }
  ],
  "summary": {
    "findings_count": { "total": 13, "critical": 3, "high": 4, "medium": 4, "low": 2 },
    "quick_wins": 6,
    "fixable": { "safe": 5, "moderate": 4, "dangerous": 2, "no_template": 2 }
  }
}
```

**Nullability:** `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` are nullable. Set to `null` for findings that have no auto-fix template (content quality, E-E-A-T, etc.). Consumers MUST check for null before using these fields.

The `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` fields enable `zuvo:seo-fix` to apply automated fixes without re-scanning the codebase.

---

## Phase 7: Backlog and Next Steps

### Backlog Persistence (optional)

**Activated with `--persist-backlog` flag.**

Emit entries to `memory/backlog.md` for findings that meet at least one condition:
- Priority >= 2.0
- Any Critical Gate = FAIL

Fingerprint format: `{file}|{dimension}|{check}` (e.g., `public/robots.txt|D5|robots-googlebot`).
Same format used by seo-fix for backlog updates. Deduplicate against existing entries.

### Next-Action Routing

| Audit Result | Proposed Action | Why |
|--------------|-----------------|-----|
| Any CG = FAIL | Fix critical gate first | CG failures block all optimization |
| GEO Score < 50 | Add llms.txt + AI crawler rules + content structure | Highest GEO ROI |
| SEO Score < 60 | Fix meta tags + canonical + sitemap gaps | Foundation issues |
| Content < 300 words avg | Expand thin content | Content quality drives all signals |
| D3 < 50 (Structured Data) | Add/fix JSON-LD schemas | Schema markup boosts citations |
| Tier A (>= 85) | Periodic re-audit or add --live-url for CWV data | Maintain and measure |

## Phase 7b: Adversarial Review on Audit Report (MANDATORY — do NOT skip)

After the audit report is generated, run cross-model validation to catch score inflation and gate inconsistency.

```bash
adversarial-review --mode audit --files "[audit report path]"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** (FAIL gate not in verdict, severity mismatch, score inflation) → fix in report before delivery
- **WARNING** (N/A abuse, skipped check, insufficient evidence) → append to Known Gaps section
- **INFO** → ignore

---

## SEO-AUDIT COMPLETE

Overall: [N]/100 -- Tier [A/B/C/D] | Result: [PASS/FAIL/PROVISIONAL]
SEO: [N]/100 | GEO: [N]/100 | Tech: [N]/100
Critical gates: [N PASS] / [N FAIL] / [N INSUFFICIENT DATA]
Findings: [N critical] / [N total]
Run: <ISO-8601-Z>	seo-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).
