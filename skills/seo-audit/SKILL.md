---
name: seo-audit
description: >
  SEO/GEO site audit covering 13 dimensions with 6 critical gates. Scans source
  code, templates, and config files across meta tags, structured
  data, AI crawlers, content quality, GEO readiness, performance, and optional
  live Core Web Vitals. Framework-aware: Astro, Next.js, Hugo, WordPress, React,
  plain HTML. Flags: full (default), [path], --live-url <url>, --quick,
  --content-only, --geo, --persist-backlog.
---

# zuvo:seo-audit — SEO/GEO Site Audit

Hybrid code-level and optional live site audit for search engine optimization and generative engine optimization. Examines source code, templates, and config files across 13 dimensions. Optional live mode adds Core Web Vitals measurement, broken link detection, and rendered DOM verification.

**Scope:** Pre-launch readiness, periodic SEO health, GEO optimization, content scaling preparation, post-redesign verification.
**Out of scope:** Code quality (`zuvo:code-audit`), security vulnerabilities (`zuvo:security-audit`), deep performance profiling (`zuvo:performance-audit`).

## Mandatory File Loading

Read these files before any work begins:

1. `{plugin_root}/shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `{plugin_root}/shared/includes/env-compat.md` -- Agent dispatch and environment adaptation

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
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

| Scenario | Static Analysis (code) | Live Tests (--live-url) |
|----------|----------------------|------------------------|
| No --live-url | Proceed (code read only) | N/A |
| --live-url localhost | Proceed | Proceed freely (GET/HEAD only) |
| --live-url staging | Proceed | Confirm with user, then proceed |
| --live-url production | Proceed | Confirm with user, then proceed. Default to code-only if confirmation is unavailable. |

**Rate limiting (live audit):** Max 2 requests/second internal, 1 req/s external. 3 consecutive 429s triggers a 30s pause. 3 consecutive 5xx results halt the live audit.

**Read-only:** GET and HEAD only. No POST/PUT/DELETE.

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

Also detect:
- **Content format:** markdown (content/posts/blog directories), database-driven, or none
- **SEO files:** robots.txt, sitemap*, llms.txt
- **Deploy platform:** Netlify, Vercel, Cloudflare, Apache, Nginx

Store results:
```
DETECTED_STACK = [astro | nextjs | hugo | wordpress | react | html]
CONTENT_FORMAT = [markdown | database | none]
```

Print:
```
Stack: [framework] | Content: [format] | Deploy: [platform]
SEO files: robots.txt [found/MISSING] | sitemap [found/MISSING] | llms.txt [found/MISSING]
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

---

## Phase 2: Code Audit (Parallel Agent Dispatch)

Dispatch 3 agents in parallel. Each agent evaluates its assigned dimensions independently.

### Dimension grouping

| Group | Agent | Dimensions | Shared data |
|-------|-------|-----------|-------------|
| A (Technical) | `agents/seo-technical.md` | D1, D4, D5, D11, D12, D13 | Config files, robots.txt, head templates |
| B (Content) | `agents/seo-content.md` | D7, D9, D10 | Content files, markdown/HTML pages |
| C (Assets) | `agents/seo-assets.md` | D2, D3, D6, D8 | Layout templates, asset files, build config |

### Agent dispatch

Refer to `../../shared/includes/env-compat.md` for dispatch patterns per environment.

**Claude Code:** Use the Agent tool to run all three in parallel:

```
Agent 1: SEO Technical (Group A)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/seo-technical.md
  input: detected_stack, [config file paths from Phase 0], codesift_repo

Agent 2: SEO Content (Group B)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/seo-content.md
  input: detected_stack, [content directory paths], codesift_repo

Agent 3: SEO Assets (Group C)
  model: "sonnet"
  type: "Explore"
  instructions: read agents/seo-assets.md
  input: detected_stack, [layout/template paths], codesift_repo
```

**Codex:** Define TOML agents per env-compat.md patterns. Each agent runs in read-only sandbox.

**Cursor:** No agent dispatch. Execute each agent's analysis sequentially yourself, maintaining identical output format.

### Waiting for results

Collect all 3 agent reports before proceeding to Phase 3 (live audit) or Phase 4 (scoring).

If an agent fails or times out:
- Retry once with same inputs
- If retry fails: log the error, proceed with results from successful agents, note the gap in the report

### Merge logic (before Phase 4)

After all agents complete:
1. Concatenate findings arrays from all 3 agents
2. Assign sequential finding IDs (F1, F2, F3, ...) across the merged list
3. Each agent returns per-dimension scores -- pass through unchanged to Phase 4 scoring
4. Evaluate critical gates: CG1-CG4, CG6 from Technical agent; CG5 from Assets agent
5. If any dimension is missing (agent failed): mark as "INSUFFICIENT DATA" in scoring

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

### 3.3 Broken Link Check

Check up to 50 internal links and 100 external links. Record status codes.

### 3.4 Visual Verification

If browser tools available, capture screenshots at 3 breakpoints (1440, 768, 375). Check for mobile rendering issues.

---

## Phase 4: Scoring

### 4.1 Evaluate Critical Gates

All 6 gates MUST have explicit status:

```
CG1: Sitemap exists                    -- from D4
CG2: Googlebot not blocked             -- from D5
CG3: HTTPS active                      -- from D11
CG4: Canonical tags present            -- from D11
CG5: JSON-LD server-side rendered      -- from D3
CG6: AI crawler policy conscious       -- from D5
```

**Critical gate statuses:**
- `PASS` -- evidence confirms gate is satisfied
- `FAIL` -- evidence confirms gate is not satisfied
- `INSUFFICIENT DATA` -- static analysis is inconclusive and no live verification is available

**Scoring rules:**
- Any critical gate = `FAIL` -> overall result = `FAIL` regardless of score
- Any critical gate = `INSUFFICIENT DATA` -> overall result = `PROVISIONAL` until live/source verification is completed
- `PROVISIONAL` does not block CI gates (it is not a FAIL) but flags incomplete assurance

### 4.2 Dimension Scores

Per-dimension: `score = (sum of check scores / count of applicable checks) * 100`

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
FAIL:      Any critical gate = 0. Must fix before any other optimization.
```

---

## Phase 5: Report Validation

Before generating the report, verify:

1. **Count Consistency:** Total checks = sum of all dimension checks
2. **Score Math:** Recalculate overall from dimension scores * weights. Must match within 0.1.
3. **Critical Gate Completeness:** All 6 gates have explicit PASS/FAIL/INSUFFICIENT DATA with evidence.
4. **Evidence Completeness:** Every FAIL finding has file:line or INSUFFICIENT DATA note.
5. **Priority Math:** Verify 3D priority calculation `(SEO * 0.4) + (Business * 0.4) + ((4 - Effort) * 0.2)`.

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

1. **Header** -- project, date, stack, mode (code / code+live)
2. **Critical Gates** -- 6 gates, PASS/FAIL with evidence
3. **Dimension Scores** -- D1-D13 table with score, weight, weighted contribution
4. **Overall Score + Tier**
5. **Sub-Scores** -- SEO, GEO, Tech (each /100)
6. **Quick Wins** -- findings with Priority >= 2.0 AND Effort = EASY
7. **Full Execution Plan** -- all findings sorted by priority descending
8. **Content Report** -- articles scanned, word counts, answer-first percentage (if content scanned)
9. **GEO Readiness Panel** -- 7 dimensions (llms.txt, AI crawlers, chunkowability, structured HTML, citation readiness, E-E-A-T, freshness)
10. **Manual Check Recommendations** -- informational only, not scored
11. **CI-Parseable Summary** -- `SEO-AUDIT-RESULT: PASS|FAIL score=NN tier=X critical=none|CG-N`

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

### Save Report

```bash
mkdir -p audit-results
```

Save to: `audit-results/seo-audit-YYYY-MM-DD.md`

Auto-increment if a report for today already exists.

### Phase 6.2: JSON Output

After saving the markdown report, also save structured JSON findings for downstream consumption by `zuvo:seo-fix` and CI pipelines.

**File:** `audit-results/seo-audit-YYYY-MM-DD.json`

Auto-increment with `-N` suffix if same-day file exists (same convention as `.md`).

**Schema:** See `../../shared/includes/audit-output-schema.md` for the full schema definition.

Serialize from Phase 4 scoring results:

```json
{
  "version": "1.0",
  "skill": "seo-audit",
  "timestamp": "[current ISO 8601]",
  "project": "[working directory absolute path]",
  "args": "[arguments from Phase 0]",
  "stack": "[detected stack from Phase 0]",
  "result": "[PASS, FAIL, or PROVISIONAL from critical gate evaluation]",
  "score": {
    "overall": [0-100],
    "tier": "[A/B/C/D/FAIL]",
    "sub_scores": {
      "seo": [0-100],
      "geo": [0-100],
      "tech": [0-100]
    }
  },
  "critical_gates": [
    { "id": "CG1", "name": "Sitemap exists", "status": "PASS|FAIL", "evidence": "..." }
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
      "evidence": "...",
      "file": null,
      "line": null,
      "fix_type": "sitemap-add",
      "fix_safety": "MODERATE",
      "fix_params": { "framework": "astro", "site_url": "https://example.com" }
    }
  ],
  "summary": {
    "findings_count": { "total": 13, "critical": 3, "high": 4, "medium": 4, "low": 2 },
    "quick_wins": 6,
    "fixable": { "safe": 5, "moderate": 4, "dangerous": 2, "no_template": 2 }
  }
}
```

The `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` fields enable `zuvo:seo-fix` to apply automated fixes without re-scanning the codebase.

---

## Phase 7: Backlog and Next Steps

### Backlog Persistence (optional)

**Activated with `--persist-backlog` flag.**

Emit entries to `memory/backlog.md` for findings that meet at least one condition:
- Priority >= 2.0
- Any Critical Gate = FAIL

Fingerprint format: `file|dimension|check-id`
Deduplicate against existing entries.

### Next-Action Routing

| Audit Result | Proposed Action | Why |
|--------------|-----------------|-----|
| Any CG = FAIL | Fix critical gate first | CG failures block all optimization |
| GEO Score < 50 | Add llms.txt + AI crawler rules + content structure | Highest GEO ROI |
| SEO Score < 60 | Fix meta tags + canonical + sitemap gaps | Foundation issues |
| Content < 300 words avg | Expand thin content | Content quality drives all signals |
| D3 < 50 (Structured Data) | Add/fix JSON-LD schemas | Schema markup boosts citations |
| Tier A (>= 85) | Periodic re-audit or add --live-url for CWV data | Maintain and measure |
