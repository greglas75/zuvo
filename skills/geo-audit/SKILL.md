---
name: geo-audit
description: "GEO (Generative Engine Optimization) readiness audit. Scans source code for AI citation signals across 12 dimensions: AI crawler access, schema graph connectivity, llms.txt, SSR rendering, freshness, chunkability, canonicalization, sitemap, BLUF structure, heading quality, citation signals, and anti-patterns. Produces tiered report (A/B/C/D) with evidence-backed findings and JSON output for geo-fix consumption."
tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash
  - Agent
---

# zuvo:geo-audit -- GEO Readiness Audit

Deep code-level audit for Generative Engine Optimization. Examines source code, templates, and config files across 12 dimensions to determine how well a site is structured for AI citation by Google AI Overviews, ChatGPT Browse, Perplexity, and Gemini.

**Scope:** GEO readiness assessment, AI citation signal audit, schema graph analysis, content chunkability evaluation, AI crawler policy review.
**Out of scope:** Traditional SEO (`zuvo:seo-audit`), code quality (`zuvo:code-audit`), security vulnerabilities (`zuvo:security-audit`), live URL crawling beyond `--live-url` flag.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/seo-bot-registry.md` -- Canonical AI/search bot taxonomy and live-probe scope
4. `../../shared/includes/seo-page-profile-registry.md` -- Profile-aware thresholds and downgrades
5. `../../shared/includes/geo-check-registry.md` -- Canonical check slugs for G1-G12
6. `../../shared/includes/geo-fix-registry.md` -- Fix type IDs, safety tiers, framework templates
7. `../../shared/includes/audit-output-schema.md` -- JSON output contract
8. `../../shared/includes/backlog-protocol.md` -- Backlog persistence contract
9. `../../shared/includes/run-logger.md` -- Run logging contract
10. `../../shared/includes/retrospective.md` -- Retrospective protocol

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md             -- [READ | MISSING -> STOP]
  2. env-compat.md                 -- [READ | MISSING -> STOP]
  3. seo-bot-registry.md           -- [READ | MISSING -> STOP]
  4. seo-page-profile-registry.md  -- [READ | MISSING -> STOP]
  5. geo-check-registry.md         -- [READ | MISSING -> STOP]
  6. geo-fix-registry.md           -- [READ | MISSING -> STOP]
  7. audit-output-schema.md        -- [READ | MISSING -> STOP]
  8. backlog-protocol.md           -- [READ | MISSING -> STOP]
  9. run-logger.md                 -- [READ | MISSING -> STOP]
  10. retrospective.md                 -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift for schema discovery, bot policy search, and template analysis when available. Fall back to Grep/Read/Glob/Bash if unavailable.

---

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- Read-Only Audit

This audit is read-only against source code.

**Allowed write targets:**
- `audit-results/` for the report file (`.md` and `.json`)
- `memory/backlog.md` only when `--persist-backlog` is explicitly enabled

**FORBIDDEN:**
- Writing to any source/production file
- Modifying application code (suggest fixes in report, do not apply)
- Installing packages or modifying dependencies

### GATE 2 -- Live Audit Consent

If `--live-url` is provided, follow the live probe consent protocol from env-compat.md. Code-only mode is the default and requires no consent.

---

## Phase 0: Parse $ARGUMENTS and Detection

### 0.1 Arguments

| Argument | Behavior |
|----------|----------|
| `[path]` | Scope to directory or file (default: `.`) |
| `--profile` | Override auto-detection: `blog`, `docs`, `ecommerce`, `marketing`, `app-shell` |
| `--cms` / `--no-cms` | Override CMS detection |
| `--live-url URL` | Enable live checks (G1 HTTP status, content negotiation) |
| `--lang LANG` | Anti-pattern language: `en` (default), `pl` |
| `--persist-backlog` | Persist findings to `memory/backlog.md` |

Default: code-only audit of current directory, auto-detect profile and CMS.

### 0.2 Stack Detection

Detect the web framework from project config files:

```bash
# Portable web framework detection (BSD/GNU compatible)
ASTRO=$(find . -maxdepth 3 -name "astro.config.*" 2>/dev/null | wc -l)
NEXT=$(find . -maxdepth 3 -name "next.config.*" 2>/dev/null | wc -l)
HUGO=$(find . -maxdepth 2 \( -name "hugo.toml" -o -name "hugo.yaml" \) 2>/dev/null | wc -l)
NUXT=$(find . -maxdepth 3 -name "nuxt.config.*" 2>/dev/null | wc -l)
SVELTEKIT=$(find . -maxdepth 3 -name "svelte.config.*" 2>/dev/null | wc -l)
GATSBY=$(find . -maxdepth 3 -name "gatsby-config.*" 2>/dev/null | wc -l)
WP=$(find . -maxdepth 3 -name "wp-config.php" 2>/dev/null | wc -l)
DOCUSAURUS=$(find . -maxdepth 3 -name "docusaurus.config.*" 2>/dev/null | wc -l)
VITEPRESS=$(find . -maxdepth 3 -path "*/.vitepress/config.*" 2>/dev/null | wc -l)
REMIX=$(find . -maxdepth 3 -name "remix.config.*" 2>/dev/null | wc -l)
```

Also detect:

**SEO/GEO files:**
- `robots.txt` -- check `public/robots.txt`, `static/robots.txt`, or framework route (`src/pages/robots.txt.ts`, `app/robots.ts`)
- `sitemap` -- check `public/sitemap*.xml`, framework config (`@astrojs/sitemap` in config, `app/sitemap.ts`), or generated output
- `llms.txt` -- check `public/llms.txt`, `static/llms.txt`
- `llms-full.txt` -- check `public/llms-full.txt`, `static/llms-full.txt`

**Deploy platform:**
- `vercel.json` or `.vercel/` -> Vercel
- `netlify.toml` or `_headers` + `_redirects` -> Netlify
- `wrangler.toml` or `_worker.js` -> Cloudflare
- `.htaccess` -> Apache
- `nginx.conf` or `/etc/nginx/` refs -> Nginx
- None detected -> Unknown

Store results:
```
DETECTED_STACK = [astro | nextjs | hugo | nuxt | sveltekit | gatsby | wordpress | docusaurus | vitepress | remix | html]
DETECTED_PLATFORM = [vercel | netlify | cloudflare | apache | nginx | unknown]
```

### 0.3 Profile Auto-Detection

Detect the site profile from codebase signals. Override with `--profile` flag.

Detection heuristics:
- **blog**: markdown/MDX files in `content/`, `src/content/`, `posts/`, or blog route patterns
- **docs**: `docs/` directory, Docusaurus/Starlight/VitePress config, or docs route patterns
- **ecommerce**: product/cart/checkout components, Shopify/Snipcart/Stripe product config
- **marketing**: no content directory, few pages, landing page patterns (fallback default)
- **app-shell**: SPA framework with no content routes, dashboard patterns

Fallback: `marketing` (safest default -- fewest content quality expectations).

Store result:
```
DETECTED_PROFILE = [blog | docs | ecommerce | marketing | app-shell]
```

### 0.4 CMS Auto-Detection

Detect CMS from code signals. Override with `--cms` or `--no-cms` flag.

Detection signals:
- **WordPress**: `wp-config.php`, `wp-content/`, PHP WordPress function calls
- **Contentful**: `@contentful/rich-text-*` imports, `contentful` SDK usage
- **Sanity**: `@sanity/client` imports, `sanity.config.*`
- **Strapi**: `@strapi/*` imports, Strapi API calls
- **Prismic**: `@prismicio/*` imports

**Headless CMS heuristic**: GraphQL queries to known CMS endpoints (`*.contentful.com`, `*.sanity.io`, `*.prismic.io`, `*.strapi.*`). Generic GraphQL usage (analytics, feature flags) does NOT trigger CMS detection.

When CMS detected:
- G9-G12 -> `INSUFFICIENT DATA`
- Executive summary shows: `SCOPE NOTICE: "CMS-backed site detected ([type]). Content quality dimensions (G9-G12) cannot be assessed from source code. Use --live-url for partial live verification."`

This is a first-class status in the report header, not a footnote.

Store result:
```
CMS_DETECTED = [wordpress | contentful | sanity | strapi | prismic | none]
```

### 0.5 seo-audit Import Protocol

Import overlapping findings from the most recent seo-audit JSON output to avoid re-auditing what seo-audit already checked.

1. Scan `audit-results/` for `seo-audit-*.json` files
2. If found, select the file with the lexicographically greatest filename (ISO date + optional `-N` suffix ensures correct ordering)
3. Extract findings with `layer: geo` from dimensions D3, D5, D9, D10. Also extract `critical_gates.CG5` status from the JSON root object (CG5 is a gate value, not a dimension finding -- handled separately).
4. Map to geo-audit dimensions:
   - D5 `robots-ai-policy` -> G1
   - D5 `llms-txt-present` -> G3
   - D3 JSON-LD checks -> G2
   - D3 CG5 (SSR) -> G4
   - D9 `heading-structure` -> G10
   - D9 `answer-first` -> G9
   - D10 `freshness` -> G5
   - D10 `semantic-html` -> G6
   - D10 `eeat-signals` -> G2/G5
5. Tag imported findings `[IMPORTED:seo-audit]` and use the seo-audit's evidence
6. If the seo-audit JSON is >48h old: emit warning "seo-audit import is stale (>48h old). Results may not reflect current codebase state."
7. If no `seo-audit-*.json` found: "No seo-audit JSON found. Running all checks from scratch."

**Dependency direction constraint:** geo-audit MAY read seo-audit output. seo-audit MUST NOT read geo-audit output. This prevents circular dependency between the two skills.

Print:
```
Stack: [framework] | Platform: [platform] | Profile: [profile] | CMS: [detected or none]
GEO files: robots.txt [found/MISSING] | sitemap [found/MISSING] | llms.txt [found/MISSING] | llms-full.txt [found/MISSING]
seo-audit import: [filename and date | "none -- running all checks from scratch"]
```

---

## Phase 1: Parallel Agent Dispatch

Dispatch 3 agents in parallel. Each agent evaluates its assigned dimensions independently and returns raw check statuses only.

### Dimension Grouping

| Group | Agent | File | Dimensions |
|-------|-------|------|-----------|
| A (Crawl & Access) | Crawl & Access Agent | `agents/geo-crawl-access.md` | G1, G7, G8 |
| B (Schema & Render) | Schema & Render Agent | `agents/geo-schema-render.md` | G2, G4, G5 |
| C (Content Signals) | Content Signals Agent | `agents/geo-content-signals.md` | G3, G6, G9, G10, G11, G12 |

### Agent Dispatch

Refer to `../../shared/includes/env-compat.md` for dispatch patterns per environment.

**Claude Code:** Use the Agent tool to run all three in parallel:

```
Agent 1: GEO Crawl & Access (Group A)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/geo-crawl-access.md
  input: detected_stack, detected_platform, detected_profile, cms_detected,
         imported_findings (G1/G7/G8 subset), file_paths, codesift_repo, lang

Agent 2: GEO Schema & Render (Group B)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/geo-schema-render.md
  input: detected_stack, detected_profile, cms_detected,
         imported_findings (G2/G4/G5 subset), file_paths, codesift_repo, lang

Agent 3: GEO Content Signals (Group C)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/geo-content-signals.md
  input: detected_stack, detected_profile, cms_detected,
         imported_findings (G3/G6/G9-G12 subset), file_paths, codesift_repo, lang
```

<!-- PLATFORM:CODEX -->
**Codex:** Define TOML agents per env-compat.md patterns. Each agent runs in read-only sandbox.
<!-- /PLATFORM:CODEX -->

<!-- PLATFORM:CURSOR -->
**Cursor:** No agent dispatch. Execute each agent's analysis sequentially yourself, maintaining identical output format.
<!-- /PLATFORM:CURSOR -->

If native agent dispatch is unavailable, run the three agent analyses sequentially yourself, preserve the same report sections, and note the fallback mode in the final audit header.

### Waiting for Results

Collect all 3 agent reports before proceeding to Phase 2. Pass to each agent: `detected_stack`, `detected_platform`, `detected_profile`, `cms_detected`, `imported_findings` (subset for that agent's dimensions), `file_paths`, `codesift_repo`, `lang`.

If an agent fails or times out:
- Retry once with same inputs
- If retry fails: log the error, proceed with results from successful agents, mark the failed agent's dimensions as `INSUFFICIENT DATA`

**Agent vs main scoring boundary:** Agents return raw check statuses (PASS/PARTIAL/FAIL/INSUFFICIENT DATA) per check. The main agent calculates all numeric scores in Phase 3. Agents do NOT calculate dimension scores themselves.

### Dimension Constraints (normative -- agents MUST follow)

#### Enforcement Model (normative)

Read `../../shared/includes/geo-check-registry.md` as the single source of truth for `owner_agent`, `layer`, `enforcement`, and `evidence_mode`.

- `blocking`: can produce overall `FAIL` or `PROVISIONAL`
- `scored`: affects dimension and overall scores, but cannot alone flip the overall result
- `advisory`: prioritized and reported, but excluded from pass/fail logic

Only `blocking` checks may produce overall `FAIL` or `PROVISIONAL`. Heuristic, advisory, or content-inaccessible findings must never create a blocking result without direct evidence.

For fix_type identifiers and safety classifications, agents MUST use `../../shared/includes/geo-fix-registry.md` as the canonical source.

**G1 -- AI Crawler Access:**
- Use `../../shared/includes/seo-bot-registry.md` for canonical bot taxonomy
- Training vs retrieval bot distinction is explicit: blocking GPTBot (training) while allowing ChatGPT-User (retrieval) is scored as PASS, not FAIL
- When Cloudflare/WAF/CDN is detected AND `--live-url` is not provided, G1 robots.txt checks are capped at PARTIAL with note: "WAF detected -- robots.txt PASS cannot be confirmed without live verification"
- WAF detection: scan for `_headers`, `wrangler.toml`, Cloudflare Pages config, Vercel `vercel.json` firewall rules

**G2 -- Schema Graph:**
- Attribute richness matters: generic minimally-populated schema underperforms no schema (41.6% vs 59.8% citation rate per Growth Marshal research)
- Check required + recommended fields per type (Organization, Article, Person, FAQPage, WebSite)
- `@graph` pattern preferred over scattered inline schemas
- Wikidata/Wikipedia `sameAs` links for entity disambiguation

**G4 -- SSR & Rendering:**
- FAIL patterns: `useEffect` + JSON-LD injection (Next.js), `client:load` island containing schema (Astro), `document.head.appendChild` with schema script
- PASS patterns: inline `<script type="application/ld+json">` in layout/page component rendered server-side

**G9-G12 -- Content Dimensions (advisory only):**
- Never produce blocking gate failures
- On CMS-detected sites: `INSUFFICIENT DATA`
- All heuristics are regex-based and deterministic, not LLM-subjective

### CodeSift Query Patterns (when available)

Use these specific queries for GEO-relevant searches:

```
search_text(repo, "application/ld+json", file_pattern="*.{astro,tsx,html,php}")
search_text(repo, "@id", file_pattern="*.{astro,tsx,html,json}")
search_text(repo, "sameAs", file_pattern="*.{astro,tsx,html,json}")
search_text(repo, "canonical", file_pattern="*.{astro,tsx,html,php}")
search_text(repo, "robots", file_pattern="*.{txt,ts,js,toml,yaml}")
search_text(repo, "sitemap", file_pattern="*.{ts,js,mjs,toml,yaml}")
search_text(repo, "llms.txt")
search_text(repo, "dateModified", file_pattern="*.{astro,tsx,html,json}")
search_text(repo, "datePublished", file_pattern="*.{astro,tsx,html,json}")
search_text(repo, "client:load", file_pattern="*.astro")
search_text(repo, "use client", file_pattern="*.{tsx,jsx}")
```

---

## Phase 2: Merge & Assign IDs

After all agents complete:

### 2.1 Concatenate Findings

Merge findings arrays from all 3 agents into a single ordered list.

### 2.2 Assign Stable IDs

Assign stable finding IDs using format `{dimension}-{check_slug}` (e.g., `G2-schema-id-disconnected`, `G1-retrieval-bots-blocked`). These IDs are deterministic across runs for the same codebase.

Also assign display-order numbers (F1, F2, ...) for human-readable reports. The stable ID is used for `--finding` filtering in geo-fix.

### 2.3 Conflict Resolution (imported vs own checks)

If an imported seo-audit finding conflicts with geo-audit's own deeper check, geo-audit's result takes precedence. Note in the finding's `confidence_reason` field:

```
"Overrides imported seo-audit finding [id] which reported [status]."
```

geo-audit's checks are deeper (e.g., `@id` graph connectivity goes beyond D3's basic schema presence check), so geo-audit's own result is authoritative.

### 2.4 Missing Dimensions

If any dimension is entirely missing (agent failed): mark all its checks as `INSUFFICIENT DATA` in scoring.

---

## Phase 3: Scoring

### 3.1 Check Status -> Numeric Value

| Status | Value | Notes |
|--------|-------|-------|
| PASS | 1.0 | Evidence confirms check passes |
| PARTIAL | 0.5 | Partially satisfied or minor issues |
| FAIL | 0.0 | Evidence confirms check fails |
| INSUFFICIENT DATA | excluded | Not counted in denominator |

### 3.2 Dimension Scores

Per dimension: `score = (sum of check values / count of non-excluded checks) * 100`

**N/A rules per dimension (exclude from overall score):**

| Dimension | N/A when |
|-----------|----------|
| G9 (BLUF) | No content corpus (no markdown/blog/pages directories) |
| G10 (Heading Structure) | No content corpus |
| G11 (Citation Signals) | `docs` or `ecommerce` profile |
| G12 (Anti-patterns) | No content corpus |

### 3.3 Critical Gates

All 4 gates MUST have explicit status:

```
GCG1: Retrieval bots not blocked in robots.txt        -- from G1
GCG2: Schema has @id field                             -- from G2
GCG3: JSON-LD is SSR-rendered (not client-only)        -- from G4
GCG4: Canonical tags present in layout                 -- from G7
```

**Critical gate statuses:**
- `PASS` -- evidence confirms gate is satisfied
- `FAIL` -- evidence confirms gate is not satisfied
- `INSUFFICIENT DATA` -- static analysis is inconclusive and no live verification is available

**Scoring rules:**
- Any blocking critical gate = `FAIL` -> overall result = `FAIL` regardless of score
- Any blocking critical gate = `INSUFFICIENT DATA` -> overall result = `PROVISIONAL` until live/source verification is completed
- `PROVISIONAL` does not block CI gates (it is not a FAIL) but flags incomplete assurance
- Only `blocking` checks and critical gates control `FAIL` vs `PROVISIONAL`. `scored` and `advisory` findings may lower scores, but they never override the overall result on their own.

**GCG2 detail:** Schema present WITHOUT `@id` = G2 dimension PARTIAL score but GCG2 FAIL. Schema absent entirely = both G2 FAIL and GCG2 FAIL.

### 3.4 Weighted Overall Score

```
Dimension weights (sum to 100%):
  G1:  15%   G2:  18%   G3:   8%   G4:  12%
  G5:  10%   G6:   7%   G7:  10%   G8:   5%
  G9:   5%   G10:  4%   G11:  3%   G12:  3%

Active weights = sum of weights where dimension is NOT N/A
Overall = sum(dimension_score * weight) / active_weights * 100
```

### 3.5 Tier Assignment

```
A (>= 85): GEO-ready. Strong AI citation signals across all dimensions.
B (70-84): Good foundation. Optimization opportunities identified.
C (50-69): Significant gaps. Prioritized fixes needed for AI visibility.
D (< 50):  Major issues. Site unlikely to be cited by AI systems.

Result overrides:
- Any blocking critical gate = FAIL -> result = "FAIL" (regardless of tier)
- Any blocking critical gate = INSUFFICIENT DATA -> result = "PROVISIONAL"
Tier is always calculated from score: A/B/C/D.
```

### 3.6 3D Priority Calculation

For each finding:
```
SEO Impact:      HIGH(3) / MEDIUM(2) / LOW(1)
Business Impact: HIGH(3) / MEDIUM(2) / LOW(1)
Fix Effort:      EASY(1) / MEDIUM(2) / HARD(3)

Priority = (SEO_impact * 0.4) + (Business_impact * 0.4) + ((4 - Effort) * 0.2)
Range: 1.0 - 3.0

Quick Win = Priority >= 2.0 AND Effort = EASY
```

**Assignment rubric (to ensure consistent scoring):**

| Factor | 3 (HIGH) | 2 (MEDIUM) | 1 (LOW) |
|--------|----------|------------|---------|
| SEO Impact | Blocks AI citation, schema graph, or crawlability (GCG fail) | Degrades citation signals or content discoverability | Cosmetic or minor optimization |
| Business Impact | Affects homepage, landing pages, or money pages | Affects secondary pages or non-revenue content | Affects low-traffic or internal pages |
| Fix Effort | 1-2 files, config change or additive insert | 3-5 files, template modification, testing needed | 6+ files, architecture change, or content creation |

---

## Phase 4: Validation

Before generating the report, verify:

1. **Count Consistency:** Total checks = sum of all dimension checks. No check counted twice.
2. **Score Math:** Recalculate overall from dimension scores * weights. Must match within 0.1.
3. **Critical Gate Completeness:** All 4 gates have explicit PASS/FAIL/INSUFFICIENT DATA with evidence.
4. **Evidence Completeness:** Every FAIL finding has file:line or INSUFFICIENT DATA note.
5. **Finding ID Uniqueness:** All stable IDs (`{dimension}-{check_slug}`) are unique. No duplicates.
6. **Display ID Sequence:** F-IDs are sequential (F1, F2, ...) with no gaps or duplicates.
7. **JSON Schema Compliance:** Output matches `audit-output-schema.md` v1.1 with `"skill": "geo-audit"`.
8. **Dimension Coverage:** All 12 dimensions (G1-G12) have at least one check result (even if INSUFFICIENT DATA or N/A).

Fix any discrepancies before presenting to user.

---

## Phase 4b: Adversarial Review on Audit Report (MANDATORY -- do NOT skip)

After the audit report is generated, run cross-model validation to catch score inflation and gate inconsistency. Runs on ALL audits.

```bash
adversarial-review --mode audit --files "audit-results/geo-audit-[date].md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** (FAIL gate not in verdict, severity mismatch, score inflation) -> fix in report before delivery
- **WARNING** (N/A abuse, skipped check, INSUFFICIENT DATA overuse) -> append to Known Gaps section
- **INFO** -> ignore

---

## Phase 5: Report

### 5.1 Executive Summary

```
GEO AUDIT -- [project name]
----
GEO Score: [N]/100 -- Tier [A/B/C/D]
Result:    [PASS / FAIL / PROVISIONAL]
Profile:   [detected or overridden profile]
CMS:       [detected type or "none"]
----
Critical Gates: [N PASS] / [N FAIL] / [N INSUFFICIENT DATA]
```

Health scale: HEALTHY (80+), NEEDS ATTENTION (60-79), AT RISK (40-59), CRITICAL (<40).

Include scope notices (CMS, WAF advisories) immediately after the summary header, not buried in findings.

If seo-audit was imported: `Imported [N] findings from seo-audit ([date]). [M] overridden by deeper geo-audit checks.`

### 5.2 Dimension Score Table

All 12 dimensions with score, weight, weighted contribution, check count, and status:

```
| Dimension | Score | Weight | Weighted | Checks | Status |
|-----------|-------|--------|----------|--------|--------|
| G1: AI Crawler Access | 85 | 15% | 12.8 | 4 | PASS |
| G2: Schema Graph | 50 | 18% | 9.0 | 6 | PARTIAL |
| ... | ... | ... | ... | ... | ... |
```

### 5.3 Critical Gates

All 4 gates with explicit PASS/FAIL/INSUFFICIENT DATA and evidence:

```
GCG1: Retrieval bots not blocked  -- [PASS/FAIL/INSUFFICIENT DATA] -- [evidence]
GCG2: Schema has @id              -- [PASS/FAIL/INSUFFICIENT DATA] -- [evidence]
GCG3: JSON-LD is SSR-rendered     -- [PASS/FAIL/INSUFFICIENT DATA] -- [evidence]
GCG4: Canonical tags present      -- [PASS/FAIL/INSUFFICIENT DATA] -- [evidence]
```

### 5.4 Findings Detail

Every finding in the execution plan uses this structure:

```
[F-ID] [Dimension] [Severity] [Confidence]
  Issue: [one-line description]
  Evidence: [file:line or "code-only inference"]
  Why it matters: [GEO/citation impact in one sentence]
  Fix: [actionable instruction]
  Priority: [N.N] (SEO=[1-3] x Biz=[1-3] x Effort=[1-3])
  Enforcement: [blocking | scored | advisory]
  Layer: [technical-geo | content-geo]
  ETA: [minutes or "n/a"]

Confidence scale:
  HIGH   = direct source evidence (file:line confirms the finding)
  MEDIUM = inferred from config or indirect signals
  LOW    = heuristic or absence-based (e.g., file not found)
See also `../../shared/includes/geo-fix-registry.md` for the canonical confidence definitions.
```

Findings sorted by:
1. Quick Wins first (Priority >= 2.0 AND Effort = EASY)
2. Then by priority descending

### 5.5 Fix Coverage Summary

Count of findings by fix category:

```
Fixable (SAFE):      [N] findings -- auto-applied by geo-fix
Fixable (MODERATE):  [N] findings -- applied with validation by geo-fix --auto
Fixable (DANGEROUS): [N] findings -- requires confirmation per fix
Out of Scope:        [N] findings -- content scaffolds only, no auto-fix
Advisory:            [N] findings -- no fix template
```

### 5.6 Next-Action Routing

| Audit Result | Proposed Action | Why |
|--------------|-----------------|-----|
| Any GCG = FAIL | Fix critical gate first | GCG failures block all AI citation optimization |
| GEO Score < 50 | Run `zuvo:geo-fix` for quick wins | Technical fixes have highest ROI |
| G2 < 50 (Schema) | Add/fix JSON-LD with `@id` connectivity | Schema graph is the strongest GEO signal |
| G1 < 50 (Crawlers) | Fix robots.txt AI bot policy | No access = no citation |
| G3 < 50 (llms.txt) | Generate llms.txt | Low effort, future-proofing |
| Tier A (>= 85) | Periodic re-audit or add `--live-url` for verification | Maintain and measure |

### 5.7 Save Report

```bash
mkdir -p audit-results
```

Save to: `audit-results/geo-audit-YYYY-MM-DD.md`

Auto-increment if a report for today already exists: `geo-audit-YYYY-MM-DD-2.md`, `geo-audit-YYYY-MM-DD-3.md`, etc.

### 5.8 JSON Output

Before generating JSON, read `../../shared/includes/audit-output-schema.md` for the schema contract. For `fix_type` values and safety classifications, reference `../../shared/includes/geo-fix-registry.md`.

After saving the markdown report, also save structured JSON findings for downstream consumption by `zuvo:geo-fix` and CI pipelines.

**File:** `audit-results/geo-audit-YYYY-MM-DD.json`

Auto-increment with `-N` suffix if same-day file exists (same convention as `.md`).

**Schema:** See `../../shared/includes/audit-output-schema.md` for the full schema definition.

Serialize from Phase 3 scoring results. Top-level structure:

```json
{
  "version": "1.1",
  "skill": "geo-audit",
  "timestamp": "[ISO 8601]",
  "project": "[absolute path]",
  "args": "[arguments]",
  "stack": "[detected stack]",
  "profile": "[detected/overridden profile]",
  "cms_detected": "[CMS type or null]",
  "seo_audit_imported": "[seo-audit date or null]",
  "result": "[PASS | FAIL | PROVISIONAL]",
  "score": {
    "overall": "[0-100]",
    "tier": "[A/B/C/D]",
    "dimensions": {
      "G1": { "score": "[0-100]", "weight": 15, "checks": "[N]", "excluded": "[N]" }
    }
  },
  "critical_gates": [
    { "id": "GCG1", "name": "Retrieval bots not blocked", "dimension": "G1", "status": "[PASS|FAIL|INSUFFICIENT DATA]", "evidence": "..." }
  ],
  "findings": [
    {
      "id": "G2-schema-id-disconnected", "display_id": "F3", "dimension": "G2",
      "check": "schema-id-disconnected", "status": "FAIL", "severity": "HIGH",
      "enforcement": "scored", "layer": "technical-geo",
      "seo_impact": 3, "business_impact": 3, "effort": 2, "priority": 2.8,
      "confidence_reason": "...", "evidence": "src/layouts/BaseLayout.astro:42",
      "file": "src/layouts/BaseLayout.astro", "line": 42,
      "fix_type": "schema-id-link", "fix_safety": "MODERATE",
      "fix_params": { "file": "src/layouts/BaseLayout.astro" },
      "eta_minutes": 20, "imported_from": null
    }
  ],
  "scope_notices": [],
  "advisories": [],
  "summary": {
    "findings_count": { "total": 0, "critical": 0, "high": 0, "medium": 0, "low": 0 },
    "quick_wins": 0,
    "fixable": { "safe": 0, "moderate": 0, "dangerous": 0, "out_of_scope": 0, "no_template": 0 }
  }
}
```

All 12 dimensions (G1-G12) must appear in `score.dimensions` with their respective weights. All 4 critical gates must appear in `critical_gates` array.

**Nullability:** `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` are nullable. Set to `null` for findings that have no auto-fix template (content quality, advisory checks, etc.). Consumers MUST check for null before using these fields.

The `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` fields enable `zuvo:geo-fix` to apply automated fixes without re-scanning the codebase.

**Extension fields** (tolerated under v1.1 unknown-key rules): `profile`, `cms_detected`, `seo_audit_imported`, `scope_notices`, `advisories`.

**CI-Parseable Summary:**
```
GEO-AUDIT-RESULT: PASS|FAIL|PROVISIONAL score=NN tier=X critical=none|GCG-N
```

---

## Phase 6: Backlog & Next Steps

### Backlog Persistence (optional)

**Activated with `--persist-backlog` flag.**

Follow `../../shared/includes/backlog-protocol.md` for the full persistence contract.

Emit entries to `memory/backlog.md` for findings that meet at least one condition:
- Priority >= 2.0
- Any Critical Gate = FAIL

Fingerprint format: `{file}|{dimension}|{check}` (e.g., `public/robots.txt|G1|retrieval-bots-blocked`).
Same format used by geo-fix for backlog updates. Deduplicate against existing entries.

### Next-Action Suggestion

After backlog persistence, suggest the next skill to run:

```
Suggested next step: zuvo:geo-fix
  [N] fixable findings detected ([M] SAFE, [K] MODERATE).
  Run `zuvo:geo-fix` to apply automated fixes, or `zuvo:geo-fix --dry-run` to preview.
```

---

## GEO-AUDIT COMPLETE

Overall: [N]/100 -- Tier [A/B/C/D] | Result: [PASS/FAIL/PROVISIONAL]
Profile: [profile] | CMS: [type or none]
Critical gates: [N PASS] / [N FAIL] / [N INSUFFICIENT DATA]
Findings: [N critical] / [N total] | Quick wins: [N]
Run: <ISO-8601-Z>	geo-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).
