# Audit-to-Fix Pipeline & SEO Audit Modernization -- Design Specification

> **Date:** 2026-03-28
> **Status:** Approved
> **Author:** zuvo:brainstorm
> **Scope:** 3 phases -- parallel agents, structured JSON output, seo-fix skill

## Problem Statement

Zuvo has 11 audit skills that produce detailed reports with prioritized findings. None of them implement fixes. Every audit ends with "here's your execution plan" and the user must manually invoke a separate skill (`zuvo:build`, `zuvo:refactor`) or fix things by hand. This is zuvo's biggest workflow gap -- and the biggest gap across all competing Claude Code skill ecosystems (114K-star ECC, 4.3K-star geo-seo-claude, 3.4K-star claude-seo -- none have audit-to-fix pipelines).

Additionally, `zuvo:seo-audit` runs all 13 dimensions sequentially despite them being independent, and no audit skill produces machine-parseable output for CI/CD gates.

**Who is affected:** Every zuvo user who runs an audit and then has to manually translate findings into code changes.

**What happens if we do nothing:** Users treat audit reports as documentation, not automation. Competing skill ecosystems will eventually close this gap. Zuvo's unique depth (CQ1-CQ22, D1-D13, S1-S14) becomes just "nice reports" instead of "reports that fix themselves."

## Design Decisions

### D1: One spec with 3 phases, not separate specs

**Chosen:** Unified spec. **Why:** Phase 3 (seo-fix) depends on Phase 2 (JSON output). Phase 2 establishes a zuvo-wide pattern for all 11 audits. One approval, clear sequencing.

### D2: JSON output alongside markdown (not a separate cache)

**Chosen:** `audit-results/seo-audit-YYYY-MM-DD.json` produced alongside the existing `.md` report. **Why:** Audits already save findings to `audit-results/`. Adding a `.json` file in the same location is the simplest path. No new directories, no cache invalidation, no separate protocol. Humans read `.md`, machines (CI + seo-fix) read `.json`.

**Rejected:** Separate `.zuvo/cache/` directory. Unnecessary complexity -- the audit results directory already exists and serves the same purpose. Cache invalidation becomes a non-issue because the `.json` is always produced fresh alongside the `.md`.

**Rejected:** CLAUDE.md hot-cache (aaron-he-zhu pattern). Fragile, unstructured, truncated by context compression.

### D3: Three-tier fix safety model

**Chosen:** SAFE (auto-apply) / MODERATE (apply + validate) / DANGEROUS (user approval required). **Why:** Domain research shows canonical URL mistakes have destroyed site rankings (95% traffic loss in documented cases). Robots.txt errors can deindex entire sites. Auto-fix without safety tiers is irresponsible. This model matches Semgrep's approach: deterministic detection, tiered remediation.

### D4: seo-fix as a new standalone skill

**Chosen:** `zuvo:seo-fix` separate from `zuvo:seo-audit`. **Why:** Audit reads code (analysis). Fix writes code (mutation). Different safety profiles, different permissions, different blast radius. Mixing them violates single responsibility. The audit's GATE 2 (read-only) would need to be violated.

### D5: Template registry over AI-generated fixes

**Chosen:** Framework-specific fix templates with deterministic application. AI assists in context-specific parameters (e.g., site URL for sitemap), but the fix structure is templated. **Why:** Reproducible, auditable, testable. An AI-generated JSON-LD schema might hallucinate properties. A template with framework-detected values won't.

---

## Solution Overview

```
zuvo:seo-audit (existing, enhanced)
  Phase 2 dimensions run in parallel (3 agent groups)
  Outputs: .md report + .json structured findings
      |
      v
audit-results/seo-audit-YYYY-MM-DD.json    <-- structured findings
      |                                          read by seo-fix AND CI
      v
zuvo:seo-fix (new skill)
  Reads .json findings
  Classifies each: SAFE / MODERATE / DANGEROUS
  Applies SAFE fixes automatically
  Applies MODERATE fixes with validation
  Reports DANGEROUS fixes as manual instructions
  Outputs: fixed files + fix report + updated backlog
```

---

## Detailed Design

### Phase 1: Parallel Agent Dispatch in seo-audit

**Current state:** All 13 dimensions run sequentially in a single agent context.

**New state:** Dimensions grouped into 3 parallel agent groups based on shared data needs:

```
Group A (Technical):  D1 (meta tags), D4 (sitemap), D5 (crawlers), D11 (security), D12 (i18n), D13 (monitoring)
  Shared data: config files, robots.txt, head templates

Group B (Content):    D7 (internal linking), D9 (content quality), D10 (GEO readiness)
  Shared data: content files, markdown/HTML pages

Group C (Assets):     D2 (OG/social), D3 (JSON-LD), D6 (images), D8 (performance)
  Shared data: layout templates, asset files, build config
```

**Dispatch pattern:**

```
Agent Group A: model=sonnet, type=Explore
  Input: detected stack, config file paths, robots.txt location
  Output: D1, D4, D5, D11, D12, D13 scores + findings

Agent Group B: model=sonnet, type=Explore
  Input: detected stack, content directory paths, page list
  Output: D7, D9, D10 scores + findings

Agent Group C: model=sonnet, type=Explore
  Input: detected stack, layout/template paths, asset paths
  Output: D2, D3, D6, D8 scores + findings
```

**Environment adaptation (per env-compat.md):**
- Claude Code: 3 parallel Tasks
- Codex: 3 TOML agents
- Cursor: sequential (fallback to current behavior)

**Phase 3 (live audit)** runs as a 4th parallel agent if `--live-url` is provided. Independent from code audit groups.

**Changes to seo-audit SKILL.md:**
- Phase 2 rewritten with agent dispatch
- New `agents/` directory: `seo-technical.md`, `seo-content.md`, `seo-assets.md`
- Main agent synthesizes results in Phase 4 (scoring) -- unchanged logic
- Phases 0, 1, 4-7 unchanged

**Agent instruction template (each agent file follows this structure):**

```markdown
# Agent: SEO [Group Name]

## Setup
- Read codesift-setup.md (discover tools independently)
- Do NOT re-detect stack -- receive detected stack from dispatcher

## Input (from dispatcher)
- detected_stack: string (astro | nextjs | hugo | wordpress | react | html)
- file_paths: string[] (relevant files for this group's dimensions)
- codesift_repo: string | null (repo identifier if CodeSift available)

## Dimensions to evaluate
[D-numbers assigned to this group]

## Output format (returned to main agent)
For each dimension:
  - dimension_id: string
  - score: number (0-100)
  - checks_total: number
  - checks_passed: number
  - findings: Finding[] (same schema as JSON output findings[])

Findings MUST include fix_type, fix_safety, fix_params for every FAIL check.
```

**Merge logic (main agent, Phase 4):**
- Collect all 3 (or 4 with live) agent outputs
- Concatenate findings arrays
- Assign sequential finding IDs (F1, F2, ...)
- Calculate dimension scores using existing Phase 4 weighting formula
- No score normalization needed -- each agent returns raw check scores

---

### Phase 2: Structured JSON Output (zuvo-wide pattern)

**What changes:** After scoring (existing Phase 4), seo-audit writes a `.json` file alongside the `.md` report.

**File:** `audit-results/seo-audit-YYYY-MM-DD.json`

Auto-incremented if same-day file exists (same as `.md`).

**JSON schema:**

```json
{
  "version": "1.0",
  "skill": "seo-audit",
  "timestamp": "2026-03-28T14:30:00Z",
  "project": "/Users/greglas/DEV/zuvo-plugin",
  "args": "full",
  "stack": "astro",
  "result": "FAIL",
  "score": {
    "overall": 53,
    "tier": "C",
    "sub_scores": {
      "seo": 61,
      "geo": 38,
      "tech": 65
    }
  },
  "critical_gates": [
    { "id": "CG1", "name": "Sitemap exists", "status": "FAIL", "evidence": "No sitemap.xml found" },
    { "id": "CG2", "name": "Googlebot not blocked", "status": "PASS", "evidence": "robots.txt:1" }
  ],
  "findings": [
    {
      "id": "F1",
      "dimension": "D4",
      "check": "sitemap-exists",
      "status": "FAIL",
      "severity": "HIGH",
      "seo_impact": 3,
      "business_impact": 3,
      "effort": 1,
      "priority": 2.8,
      "evidence": "No sitemap.xml or sitemap generation config found",
      "file": null,
      "line": null,
      "fix_type": "sitemap-add",
      "fix_safety": "MODERATE",
      "fix_params": {
        "framework": "astro",
        "site_url": "https://zuvo.dev"
      }
    }
  ],
  "summary": {
    "findings_count": { "total": 13, "critical": 3, "high": 4, "medium": 4, "low": 2 },
    "quick_wins": 6,
    "fixable": { "safe": 5, "moderate": 4, "dangerous": 2, "no_template": 2 }
  }
}
```

**Key fields for seo-fix:**
- `findings[].fix_type` -- maps to template registry
- `findings[].fix_safety` -- SAFE / MODERATE / DANGEROUS
- `findings[].fix_params` -- framework-specific parameters for the template

**Key fields for CI:**
- `result` -- PASS or FAIL
- `score.overall` -- numeric score for threshold gates
- `critical_gates[].status` -- which gates failed

**Zuvo-wide adoption pattern:**

This JSON schema has required fields (every audit) and optional fields (fix-capable audits):

```
Required (every audit skill):
  version, skill, timestamp, project, args, stack, result
  score: { overall, tier }
  critical_gates: [{ id, name, status, evidence }]
  findings: [{ id, dimension, check, status, severity, priority, evidence, file, line }]

Optional (when audit supports fixes):
  findings[].fix_type
  findings[].fix_safety
  findings[].fix_params
```

Documented in `shared/includes/audit-output-schema.md` for adoption by other audit skills.

**CI gate usage:**

```yaml
# GitHub Actions example
- name: SEO Audit
  run: claude -p "zuvo:seo-audit --quick"

- name: Check SEO Gate
  run: |
    RESULT=$(jq -r '.result' audit-results/seo-audit-*.json)
    SCORE=$(jq -r '.score.overall' audit-results/seo-audit-*.json)
    if [ "$RESULT" = "FAIL" ] || [ "$SCORE" -lt 70 ]; then
      echo "SEO gate failed: $RESULT (score: $SCORE)"
      exit 1
    fi
```

---

### Phase 3: zuvo:seo-fix (new skill)

**Purpose:** Read seo-audit JSON findings. Apply fixes based on safety tier. Verify. Report.

**Routing (added to using-zuvo router):**

```
| Fix SEO audit findings, apply SEO fixes | `zuvo:seo-fix` |
```

**Arguments:**

| Argument | Behavior |
|----------|----------|
| (default) | Read latest JSON, apply SAFE fixes, recommend MODERATE + DANGEROUS |
| `--auto` | Apply SAFE + MODERATE fixes automatically (skip DANGEROUS) |
| `--all` | Apply all fixes including DANGEROUS (requires confirmation) |
| `--dry-run` | Show what would be fixed, change nothing |
| `--finding F1,F3` | Fix specific findings by ID |
| `--category sitemap,json-ld` | Fix specific fix_type categories |
| `[json-path]` | Use specific JSON file instead of latest |

**Phases:**

#### Phase 0: Load Findings

1. Find latest `audit-results/seo-audit-*.json` (sort by date in filename)
2. If no JSON found: "No audit JSON found. Run `zuvo:seo-audit` first."
3. Check age from `timestamp` field. If >24h: warn "Audit is N hours old. Consider re-running `zuvo:seo-audit` for fresh results."
4. Parse findings array. Print summary:

```
AUDIT: seo-audit 2026-03-28 (2h ago) | Score: 53/100 (C) | 13 findings
  SAFE:      5 findings (auto-fixable)
  MODERATE:  4 findings (fixable with validation)
  DANGEROUS: 2 findings (manual only)
  SKIP:      2 findings (no template available)
```

#### Phase 1: Detect Framework & Targets

Reuse seo-audit Phase 0.2 stack detection. Map each finding's `fix_type` to a template:

**Template Registry:**

| fix_type | Framework | Template | Target File |
|----------|-----------|----------|-------------|
| `sitemap-add` | astro | Install `@astrojs/sitemap`, add to integrations, ensure `site:` set | `astro.config.mjs` |
| `sitemap-add` | nextjs | Create `app/sitemap.ts` with route export | `app/sitemap.ts` (new) |
| `sitemap-add` | hugo | Set `enableRobotsTXT = true`, add `[sitemap]` config | `hugo.toml` |
| `json-ld-add` | astro | Add `<script type="application/ld+json" set:html={...} />` to layout head | `src/layouts/*.astro` |
| `json-ld-add` | nextjs | Add `<script dangerouslySetInnerHTML>` in layout.tsx | `app/layout.tsx` |
| `json-ld-add` | hugo | Create `layouts/partials/json-ld.html`, include in head | `layouts/partials/json-ld.html` (new) |
| `meta-og-add` | astro | Add `<meta property="og:*">` tags to head component | `src/components/BaseHead.astro` or layout |
| `meta-og-add` | nextjs | Add to `metadata` export in layout.tsx | `app/layout.tsx` |
| `meta-og-add` | hugo | Add OG meta tags to `layouts/partials/head/opengraph.html` | `layouts/partials/head/opengraph.html` |
| `robots-fix` | astro | Create/fix `public/robots.txt` or `src/pages/robots.txt.ts` | `public/robots.txt` |
| `robots-fix` | nextjs | Create `app/robots.ts` with rules export | `app/robots.ts` (new) |
| `robots-fix` | hugo | Set `enableRobotsTXT = true`, create `layouts/robots.txt` template | `hugo.toml` + `layouts/robots.txt` |
| `llms-txt-add` | * | Create `public/llms.txt` with site structure | `public/llms.txt` (new) |
| `headers-add` | cloudflare | Create `public/_headers` with security headers | `public/_headers` (new) |
| `headers-add` | vercel | Add `headers` to `vercel.json` or `next.config.js` | `vercel.json` or `next.config.js` |
| `headers-add` | netlify | Create `public/_headers` or add to `netlify.toml` | `public/_headers` (new) |
| `canonical-fix` | astro | Set `site:` in config, add canonical `<link>` in layout | `astro.config.mjs` + layout |
| `canonical-fix` | nextjs | Add `alternates.canonical` to metadata export | `app/layout.tsx` |
| `canonical-fix` | hugo | Verify `baseURL` in config, add `<link rel="canonical">` via `.Permalink` | `hugo.toml` + head partial |
| `font-display-add` | * | Add `font-display: swap` to `@font-face` declarations | CSS files with `@font-face` |
| `lang-attr-add` | * | Add `lang` attribute to `<html>` element | Layout/template files |
| `alt-text-add` | * | Add empty `alt=""` to decorative images | Component files with `<img>` |
| `viewport-add` | * | Add `<meta name="viewport">` to head | Layout head |

**Note on WordPress/React/plain HTML:** Template registry covers Astro, Next.js, and Hugo as primary frameworks. WordPress fixes are plugin-based (Yoast/RankMath config, not code changes) -- outside auto-fix scope. React SPAs without SSR have limited SEO value -- seo-fix will warn and skip. Plain HTML gets universal (*) templates only.

**Safety classification (per framework):**

| fix_type | astro | nextjs | hugo | * (universal) |
|----------|-------|--------|------|---------------|
| `llms-txt-add` | SAFE | SAFE | SAFE | SAFE |
| `headers-add` | SAFE | SAFE | SAFE | SAFE |
| `font-display-add` | SAFE | SAFE | SAFE | SAFE |
| `lang-attr-add` | SAFE | SAFE | SAFE | SAFE |
| `alt-text-add` | SAFE | SAFE | SAFE | SAFE |
| `viewport-add` | SAFE | SAFE | SAFE | SAFE |
| `sitemap-add` | MODERATE (pkg install) | MODERATE (new file) | SAFE (config toggle) | -- |
| `json-ld-add` | MODERATE | MODERATE | MODERATE | -- |
| `meta-og-add` | MODERATE | MODERATE | MODERATE | -- |
| `robots-fix` | MODERATE | MODERATE | MODERATE | -- |
| `canonical-fix` | DANGEROUS | DANGEROUS | DANGEROUS | -- |

**Explicitly out of scope for fix templates:** `noindex-change` and `redirect-add`. These require HTTP-level configuration decisions that vary too much across deploy platforms. They appear in audit findings as manual recommendations only, never as fixable items.

**Fix Parameters Schema (required per fix_type):**

| fix_type | Required params | Optional params | Notes |
|----------|-----------------|-----------------|-------|
| `sitemap-add` | `framework` | `site_url` | `site_url` null if not in config -- seo-fix will prompt or skip |
| `json-ld-add` | `framework`, `schema_types` | `org_name`, `site_name` | `schema_types`: array, e.g., `["WebSite", "Organization"]` |
| `meta-og-add` | `framework`, `missing_tags` | `site_url`, `default_image` | `missing_tags`: e.g., `["og:locale", "twitter:image"]` |
| `robots-fix` | `framework`, `issue` | `current_rules` | `issue`: "missing" or "malformed" or "blocking-googlebot" |
| `llms-txt-add` | -- | `site_name`, `pages` | Universal. `pages` derived from sitemap or file tree |
| `headers-add` | `platform` | -- | `platform`: cloudflare, vercel, netlify |
| `canonical-fix` | `framework` | `site_url` | DANGEROUS. `site_url` required for safe application |
| `font-display-add` | -- | `font_files` | Universal. `font_files`: paths to CSS with @font-face |
| `lang-attr-add` | -- | `locale` | Default: `en`. Derived from config if available |
| `alt-text-add` | -- | `image_files` | Universal. Only decorative images (no content images) |
| `viewport-add` | -- | -- | Universal. Standard viewport meta tag |

#### Phase 2: Apply Fixes (batch, per safety tier)

**SAFE fixes (auto-applied):**

For each SAFE finding:
1. Read target file (or confirm new file path)
2. Apply template with `fix_params` from JSON
3. Verify: file exists, content injected correctly (grep for expected pattern)
4. Record: `{ finding_id, action, file, status: "FIXED" }`

**MODERATE fixes (applied with validation):**

For each MODERATE finding:
1. Read target file + surrounding context
2. Apply template
3. **Validation step:**
   - Sitemap: verify `site` URL is configured, integration added correctly
   - JSON-LD: validate schema properties against schema.org required fields
   - Meta tags: verify image URLs are absolute, not relative
   - Robots.txt: verify Googlebot is NOT blocked after fix (re-check CG2)
4. If validation fails: revert, mark as `NEEDS_REVIEW`
5. Record: `{ finding_id, action, file, status: "FIXED" | "NEEDS_REVIEW", validation }`

**DANGEROUS fixes (reported only, unless --all):**

For each DANGEROUS finding:
1. Generate the exact diff that would be applied
2. Explain the risk
3. Print: "This fix requires manual review. Apply with `zuvo:seo-fix --finding F7 --all`"
4. Record: `{ finding_id, action, file, status: "MANUAL", diff, risk }`

#### Phase 3: Verify

After all fixes applied:
1. If build tool available: run build (`astro build`, `next build`, etc.) -- fail = revert last fix
2. Re-run critical gate checks on modified files (CG1-CG6 subset)
3. Compare: before/after scores from JSON vs quick re-check

#### Phase 4: Report

```
SEO FIX REPORT -- [project name]
----
Findings: 13 total | 7 fixed | 2 needs review | 2 manual | 2 skipped
Score:    53 -> 78 (estimated, re-audit for exact)
----

FIXED (auto-applied):
  F2: Added llms.txt                              public/llms.txt (new)
  F5: Added security headers                      public/_headers (new)
  F8: Added font-display: swap                    src/styles/global.css:14
  F9: Added lang="en" to <html>                   src/layouts/Layout.astro:1
  F11: Added viewport meta tag                    src/layouts/Layout.astro:7

FIXED (validated):
  F1: Added @astrojs/sitemap integration           astro.config.mjs:3,8
  F3: Added JSON-LD (WebSite + Organization)       src/layouts/Layout.astro:12

NEEDS REVIEW:
  F4: robots.txt fix -- validation warning         public/robots.txt
      Warning: existing rules modified. Verify Googlebot access.
  F6: OG image meta -- relative URL detected       src/layouts/Layout.astro
      Warning: og:image uses relative path. Provide absolute URL.

MANUAL (user action required):
  F7: Canonical URL configuration                  DANGEROUS -- wrong canonical can deindex pages
      Suggested diff: [shows exact changes]
  F10: Add hreflang tags                           DANGEROUS -- incorrect hreflang causes duplicate content
      Suggested diff: [shows exact changes]

SKIPPED:
  F12: Content quality < 300 words                 No template -- requires human writing
  F13: E-E-A-T author information                  No template -- requires real data

NEXT STEPS:
  1. Review NEEDS_REVIEW items above
  2. Apply MANUAL fixes if appropriate: zuvo:seo-fix --finding F7,F10 --all
  3. Re-audit for exact score: zuvo:seo-audit
  4. Expand thin content (F12): write 300+ words per page
```

#### Phase 5: Update Backlog

1. Update backlog (per `shared/includes/backlog-protocol.md`):
   - For each FIXED finding: compute fingerprint `{file}|D{dimension}|{fix_type}`, remove the row from backlog
   - For each NEEDS_REVIEW finding: if exists in backlog, increment `Seen` count, keep OPEN
   - For each MANUAL finding: compute fingerprint, add as OPEN if not already present (severity from JSON)
   - For each SKIPPED finding (no template): add to backlog as OPEN with category "seo-manual"
2. Save report to `audit-results/seo-fix-YYYY-MM-DD.md`
3. Save fix JSON to `audit-results/seo-fix-YYYY-MM-DD.json`:

```json
{
  "result": "PARTIAL",
  "source_audit": "audit-results/seo-audit-2026-03-28.json",
  "before_score": 53,
  "estimated_after_score": 78,
  "fixed": 7,
  "needs_review": 2,
  "manual": 2,
  "skipped": 2,
  "files_modified": ["astro.config.mjs", "src/layouts/Layout.astro", "public/llms.txt", "public/_headers"]
}
```

---

## Acceptance Criteria

### Phase 1: Parallel Agents
1. seo-audit dispatches 3 agent groups in parallel on Claude Code
2. Dimension scores are identical to sequential execution (same checks, same scoring)
3. Wall-clock time reduced by 40%+ on repos with 50+ files
4. Cursor/Codex fallback to sequential works without error
5. Agent instruction files exist at `skills/seo-audit/agents/seo-technical.md`, `seo-content.md`, `seo-assets.md`

### Phase 2: JSON Output
6. `audit-results/seo-audit-YYYY-MM-DD.json` produced alongside `.md` after every audit
7. JSON validates against documented schema (version, findings[], score, critical_gates)
8. `shared/includes/audit-output-schema.md` exists documenting required and optional fields
9. JSON is valid and parseable by `jq`
10. Existing `.md` report unchanged (backward compatible)
11. Other audit skills can adopt the same JSON schema without schema changes

### Phase 3: seo-fix
12. `zuvo:seo-fix` registered in using-zuvo routing table
13. Default mode applies SAFE fixes, recommends MODERATE + DANGEROUS
14. `--auto` mode applies SAFE + MODERATE with validation
15. `--dry-run` mode changes zero files
16. Template registry covers 3 primary frameworks (Astro, Next.js, Hugo) x 10 fix types + 6 universal fix types
17. MODERATE fixes include validation step (no blind application)
18. DANGEROUS fixes never auto-applied without `--all` + user confirmation
19. Build verification runs after fixes when build tool available
20. Fix report saved to `audit-results/seo-fix-YYYY-MM-DD.md` + `.json`
21. Backlog updated per backlog-protocol.md: FIXED rows removed, MANUAL/SKIPPED rows added with fingerprint dedup

---

## Out of Scope

- **Automated content generation:** seo-fix does NOT write blog posts or page content. Thin content findings are classified as "no template."
- **Image generation:** OG images require design. seo-fix can scaffold placeholder but not create production images.
- **Multi-site crawling:** seo-fix works on the local codebase, not remote URLs.
- **Auto-running seo-fix after seo-audit:** Each skill is invoked separately. No auto-chaining. User controls the workflow.
- **JSON adoption by other audits:** This spec adds JSON to seo-audit only. Other audits adopt the same schema incrementally in future work.
- **WordPress fixes:** WordPress SEO is plugin-based (Yoast/RankMath settings), not code-level. Outside seo-fix scope.
- **React SPA fixes:** SPAs without SSR have fundamentally limited SEO. seo-fix warns and skips.
- **Redirect and noindex management:** Too platform-dependent (Cloudflare rules, Vercel rewrites, .htaccess, nginx). Manual only.
- **Content writing/rewriting:** Thin content and E-E-A-T gaps require human judgment, not templates.

## Open Questions

None. All design decisions resolved during brainstorm.

---

## Implementation Sequence

```
Phase 1 (parallel agents)     -- seo-audit internal, no dependencies
    |
Phase 2 (JSON output)         -- seo-audit writes .json alongside .md
    |
Phase 3 (seo-fix)             -- new skill, reads JSON from Phase 2
```

Phase 1 and 2 can ship together (no dependency between them). Phase 3 requires Phase 2.

## Competitive Position

After implementation, zuvo will be the **only skill ecosystem** with:
- Structured multi-dimensional audits (existing)
- Parallel agent dispatch for audit speed (Phase 1)
- Machine-parseable audit output for CI gates (Phase 2)
- **Automated audit-to-fix pipeline** (Phase 3) -- no competitor has this
- CI-parseable output for deployment gates (Phase 2)

Closest competitor: aaron-he-zhu/seo-geo-claude-skills (611 stars) has inter-skill caching but no auto-fix. No competitor in any category (Claude Code, Cursor, Codex plugins) has audit-to-fix automation.
