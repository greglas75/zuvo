---
name: a11y-audit
description: >
  Dedicated WCAG 2.2 AA/AAA accessibility audit across 10 dimensions (A1-A10)
  covering semantic HTML, keyboard navigation, ARIA patterns, color contrast,
  forms, images/media, responsive/zoom, motion/animation, reading/content, and
  legal compliance. Goes far beyond surface-level design-review checks with
  deep compliance-focused analysis, WCAG criterion mapping, and legal risk
  assessment (ADA Title II, EAA, Section 508). Critical gates on keyboard (A2)
  and contrast (A4). Flags: [path] | full | --live-url <url> | --quick |
  --fix | --standard AA|AAA | --legal ada|eaa|508.
---

# zuvo:a11y-audit — WCAG 2.2 Accessibility Audit

Deep, compliance-focused accessibility audit across 10 weighted dimensions with WCAG 2.2 criterion mapping, legal risk assessment, and actionable fix generation. Every finding maps to a specific WCAG success criterion and severity level.

**When to use:** Before public launches, when targeting WCAG compliance, after ADA/EAA legal requirements surface, periodic accessibility health checks, when onboarding a codebase that must meet compliance standards, after adding interactive components or forms.
**Out of scope:** Surface-level design consistency (`zuvo:design-review`), visual design quality (`zuvo:ui-design-team`), code quality (`zuvo:code-audit`), penetration testing (`zuvo:pentest`).

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Argument | Effect |
|----------|--------|
| `[path]` | Audit a specific directory or component |
| `full` | Audit the entire project |
| `--live-url <url>` | Enable browser-based testing (axe-core via MCP) |
| `--quick` | Critical gates only (A2 Keyboard, A4 Contrast) |
| `--fix` | Generate fix code for all findings |
| `--standard AA\|AAA` | Compliance level (default: AA) |
| `--legal ada\|eaa\|508` | Focus on a specific legal standard |
| `--max-files [N]` | Cap audit to N files (default: 40) |
| `--persist-backlog` | Emit backlog entries for CRITICAL/HIGH findings |

| Mode | Scope | Phases | Browser |
|------|-------|--------|---------|
| `[path]` | Directory/component | 0-5 | No |
| `full` | Entire project | 0-5 | No |
| `--live-url` | Project + URL | 0-5 incl. Phase 2 browser | Yes |
| `--quick` | Project | 0, 1 (A2+A4 only), 5 | No |

## Mandatory File Loading

Read these files before any work begins. Print the checklist with status.

**Stage 1 -- Before Phase 0 (STOP if any missing):**

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md  -- [READ | MISSING -> STOP]
  2. ../../shared/includes/env-compat.md      -- [READ | MISSING -> STOP]
```

**Stage 2 -- Before Phase 5 (report writing):**

```
  3. ../../shared/includes/run-logger.md      -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md      -- [READ | MISSING -> STOP]
  4. ../../shared/includes/backlog-protocol.md -- [READ | MISSING -> degraded]
```

Stage 2 deferred to save upfront context.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**a11y-audit CodeSift usage:**
- `search_text(repo, "aria-|role=", regex=true, file_pattern="*.tsx")` -- ARIA attribute scan
- `search_text(repo, "<h[1-6]", regex=true, file_pattern="*.tsx")` -- heading inventory
- `search_text(repo, "tabindex\|tabIndex", regex=true)` -- tabindex usage
- `search_text(repo, ":focus-visible\|:focus", regex=true, file_pattern="*.css")` -- focus style scan
- `search_text(repo, "prefers-reduced-motion", file_pattern="*.css")` -- motion media query
- `search_text(repo, "alt=", file_pattern="*.tsx")` -- alt text coverage
- `search_symbols(repo, "useReducedMotion|usePrefersReducedMotion", include_source=true)` -- motion hook usage

### Degraded Mode (CodeSift unavailable)

| CodeSift tool | Fallback | Lost capability |
|---------------|----------|-----------------|
| `search_text` (ARIA) | `Grep` for ARIA attributes | Same coverage, more tokens |
| `search_symbols` (hooks) | `Grep` for hook names | Less precise matches |
| `get_file_tree` | `find` command | Slower, no symbol counts |
| `get_file_outline` | `Read` each file | More tokens consumed |

---

## Dimensions (A1-A10)

### A1: Semantic HTML (weight 10)

| Check | WCAG | Detection |
|-------|------|-----------|
| Heading hierarchy (h1-h6 in order, no skips) | 1.3.1 | Scan for `<h1>`-`<h6>` ordering per page/component |
| Landmark regions (nav, main, aside, footer, header) | 1.3.1 | Grep for landmark elements or ARIA landmark roles |
| Lists used for list content (not divs) | 1.3.1 | Pattern: repeated sibling divs that should be `<ul>/<li>` |
| Tables with proper thead/th/scope | 1.3.1 | Grep for `<table>` without `<th>` or missing `scope` |
| Buttons vs links (button for actions, a for navigation) | 4.1.2 | `<a>` with `onClick` and no `href`, `<div>` with click handlers |

### A2: Keyboard Navigation (weight 12, CRITICAL GATE)

| Check | WCAG | Detection |
|-------|------|-----------|
| All interactive elements focusable | 2.1.1 | `<div onClick>` without `tabIndex` or `role="button"` |
| Tab order matches visual order (no positive tabindex) | 2.4.3 | `tabindex` values > 0 |
| Focus visible on all interactive elements | 2.4.7 | `:focus-visible` or `:focus` styles present for interactive elements |
| No keyboard traps | 2.1.2 | Modal/dialog without escape handler, custom widgets without blur path |
| Skip navigation link present | 2.4.1 | First focusable element links to `#main` or `#content` |
| Custom component keyboard handlers | 2.1.1 | Custom interactive elements missing `onKeyDown`/`onKeyUp` for Enter, Space, Escape, Arrow keys |
| Modal/dialog focus management | 2.4.3 | Focus trapped inside modal, focus returns to trigger on close |

### A3: ARIA Patterns (weight 10)

| Check | WCAG | Detection |
|-------|------|-----------|
| ARIA roles match component behavior | 4.1.2 | Role attribute vs actual element behavior |
| aria-label/aria-labelledby on elements without visible text | 4.1.2 | Icon buttons, image-only links without label |
| aria-expanded on toggleable elements | 4.1.2 | Dropdowns, accordions missing `aria-expanded` |
| aria-live regions for dynamic content | 4.1.3 | Toast, notification, status updates without `aria-live` |
| aria-hidden on decorative elements | 4.1.2 | Decorative icons/images without `aria-hidden="true"` |
| No redundant ARIA | 4.1.2 | `role="button"` on `<button>`, `role="link"` on `<a>` |
| aria-describedby for form field help text | 1.3.1 | Help text near inputs without association |

### A4: Color & Contrast (weight 10, CRITICAL GATE)

| Check | WCAG | Detection |
|-------|------|-----------|
| Text contrast >= 4.5:1 (normal), >= 3:1 (large) | 1.4.3 | Extract color values from CSS/tokens, compute ratios |
| UI component contrast >= 3:1 | 1.4.11 | Border, icon, form control colors vs background |
| Information not conveyed by color alone | 1.4.1 | Status indicators, error states using only color |
| Focus indicator contrast >= 3:1 | 1.4.11 | Focus ring color vs surrounding background |
| Light and dark theme coverage | 1.4.3 | Both themes checked if `prefers-color-scheme` or theme toggle exists |

### A5: Forms & Inputs (weight 10)

| Check | WCAG | Detection |
|-------|------|-----------|
| Every input has associated label | 1.3.1, 3.3.2 | `<input>` without `<label>`, `aria-label`, or `aria-labelledby` |
| Error messages linked to fields | 3.3.1 | Error elements without `aria-describedby` or `aria-errormessage` |
| Required fields marked | 3.3.2 | Missing `aria-required="true"` and no visual indicator |
| Autocomplete attributes on common fields | 1.3.5 | Name, email, phone, address inputs without `autocomplete` |
| Form validation errors announced | 4.1.3 | Error summary not in `aria-live` region |
| Related fields grouped | 1.3.1 | Radio groups, address fields without `<fieldset>`/`<legend>` |

### A6: Images & Media (weight 8)

| Check | WCAG | Detection |
|-------|------|-----------|
| Informative images have alt text | 1.1.1 | `<img>` without `alt`, or `alt="image"` / `alt="photo"` |
| Decorative images have alt="" or aria-hidden | 1.1.1 | Decorative images with meaningful alt |
| Complex images have long description | 1.1.1 | Charts, diagrams without `aria-describedby` or `<figcaption>` |
| Video has captions/subtitles | 1.2.2 | `<video>` without `<track kind="captions">` |
| Audio has transcript | 1.2.1 | `<audio>` without transcript link |
| SVG has title or aria-label | 1.1.1, 4.1.2 | `<svg>` without `<title>` or `aria-label` |
| No auto-playing media | 1.4.2 | `autoplay` attribute without pause control |

### A7: Responsive & Zoom (weight 6)

| Check | WCAG | Detection |
|-------|------|-----------|
| Content reflows at 320px width | 1.4.10 | Horizontal scroll triggers, fixed-width containers |
| Text resizable to 200% | 1.4.4 | Font sizes in `px` instead of `rem`/`em` |
| Touch targets minimum 44x44px | 2.5.8 | Small click/tap targets (links, buttons, icons) |
| No content hidden at zoom | 1.4.10 | `overflow: hidden` on containers with text |
| Viewport no disable scaling | 1.4.4 | `maximum-scale=1` or `user-scalable=no` in viewport meta |

### A8: Motion & Animation (weight 5)

| Check | WCAG | Detection |
|-------|------|-----------|
| prefers-reduced-motion respected | 2.3.3 | CSS `@media (prefers-reduced-motion)` present |
| No content flashes > 3 times/sec | 2.3.1 | Animation durations < 333ms with repeating patterns |
| Animations can be paused/stopped | 2.2.2 | Auto-playing animations without pause control |
| Carousels have pause control | 2.2.2 | Auto-advancing carousels without pause button |
| Page transitions respect reduced motion | 2.3.3 | Route transitions without motion preference check |

### A9: Reading & Content (weight 5)

| Check | WCAG | Detection |
|-------|------|-----------|
| html lang attribute set | 3.1.1 | `<html>` without `lang` attribute |
| Language changes marked | 3.1.2 | Foreign-language content without `lang` attribute |
| Link text is descriptive | 2.4.4 | "click here", "read more", "learn more" without context |
| Consistent navigation | 3.2.3 | Nav component differs across pages |
| Page titles descriptive and unique | 2.4.2 | Missing `<title>`, duplicate titles, generic titles |

### A10: Legal Compliance Status (NOT scored — separate legal risk section)

A10 is a **qualitative legal risk assessment**, not a scored dimension. It does NOT contribute to the numerical score (to avoid double-counting A1-A9 results). It appears as a standalone section in the report.

| Check | Standard | Detection |
|-------|----------|-----------|
| ADA Title II compliance (deadline: 2026-04-24) | ADA | Map A1-A9 failures to ADA requirements. If audit date < deadline: flag as APPROACHING. If audit date >= deadline: flag as POST-DEADLINE (compliance now mandatory). |
| European Accessibility Act compliance | EAA | Map failures to EAA requirements (if EU-facing) |
| Section 508 compliance | 508 | Map failures to Section 508 (if government) |
| VPAT readiness | VPAT | Assess documentation completeness for VPAT generation |
| Accessibility statement present | All | Check for /accessibility page or statement in footer |

---

## Phase 0: Detection

1. **Detect framework:** React, Next.js, Vue, Nuxt, Svelte, SvelteKit, Astro, Angular, plain HTML
   - Check `package.json` dependencies, config files (`next.config.*`, `astro.config.*`, `svelte.config.*`, `angular.json`)
2. **Detect component library:** MUI, Chakra, Radix, Headless UI, shadcn, Mantine, Ant Design, none
   - Check `package.json` dependencies
3. **Detect existing a11y tooling:**
   - `eslint-plugin-jsx-a11y` in devDependencies
   - `axe-core` or `@axe-core/*` in devDependencies
   - `pa11y` in devDependencies or global
   - `jest-axe` or `vitest-axe` in devDependencies
   - Storybook a11y addon (`@storybook/addon-a11y`)
4. **Detect existing a11y config:**
   - `.axerc` or `axe.config.js`
   - `.pa11y` or `.pa11yci`
   - `eslintrc` with jsx-a11y rules
5. **Estimate scope:** Count pages/components for workload sizing

Output:
```
A11Y DETECTION
  Framework:   [name]
  Components:  [library or "custom"]
  A11y tools:  [list or "none detected"]
  A11y config: [list or "none"]
  Scope:       [N pages, N components]
  Standard:    WCAG 2.2 [AA|AAA]
  Legal focus:  [ADA Title II | EAA | Section 508 | N/A]
```

---

## Phase 1: Static Code Analysis (A1-A9)

Scan templates, JSX/TSX, CSS, and config files against all dimension checks.

### 1.1 Batch Scans

Run grep/CodeSift scans across the codebase for:

| Scan | Target | Dimension |
|------|--------|-----------|
| Heading inventory | `<h1>`-`<h6>` elements per file | A1 |
| Landmark elements | `<nav>`, `<main>`, `<aside>`, `<header>`, `<footer>` | A1 |
| ARIA attributes | `aria-*` attribute usage and coverage | A3 |
| Focus styles | `:focus-visible`, `:focus`, `outline:` in CSS | A2 |
| Tabindex usage | `tabindex`/`tabIndex` values | A2 |
| Skip nav link | First focusable element pattern | A2 |
| Keyboard handlers | `onKeyDown`, `onKeyUp`, `onKeyPress` on custom elements | A2 |
| Color values | Hardcoded hex/rgb in CSS, contrast-relevant variables | A4 |
| Alt text | `alt=` attribute presence and quality | A6 |
| Form labels | `<label>`, `aria-label`, `aria-labelledby` on inputs | A5 |
| Autocomplete | `autocomplete` on common input types | A5 |
| Viewport meta | `viewport` meta tag content | A7 |
| Reduced motion | `prefers-reduced-motion` media query | A8 |
| Lang attribute | `<html lang=` in root templates | A9 |
| Link text | "click here", "read more", "learn more" patterns | A9 |
| SVG accessibility | `<title>` or `aria-label` on SVGs | A6 |

### 1.2 eslint-plugin-jsx-a11y Integration

If `eslint-plugin-jsx-a11y` is detected:
1. **Grep the ESLint config** for disabled `jsx-a11y/*` rules — note each as an intentional exception
2. **Run with project config:** `npx eslint --ext .jsx,.tsx [scope]` — captures what the project considers violations
3. **Run baseline scan:** `npx eslint --no-eslintrc --plugin jsx-a11y --rule '{...}' [scope]` — captures ALL violations including intentionally suppressed ones
4. **Diff the two runs** — suppressions found in config but not in baseline are intentional exceptions. Report them as `[SUPPRESSED]` findings (user decided to allow this) vs `[ACTIVE]` findings (violations the project config also flags)

If not available: skip, rely on manual scan.

### 1.3 Per-Component Scoring

For each page/component in scope, evaluate A1-A9 checks:

```
### [file path]
Component type: [PAGE | FEATURE | SHARED]
| Dim | Score | Max | Evidence |
|-----|-------|-----|----------|
| A1  | [N]   | 10  | [summary] |
| A2  | [N]   | 12  | [summary] |
| A3  | [N]   | 10  | [summary] |
| A4  | [N]   | 10  | [summary] |
| A5  | [N]   | 10  | [summary] |
| A6  | [N]   | 8   | [summary] |
| A7  | [N]   | 6   | [summary] |
| A8  | [N]   | 5   | [summary] |
| A9  | [N]   | 5   | [summary] |
Critical gates: A2=[N]/12 A4=[N]/10 -- [PASS/FAIL]
```

**Scoring per dimension:** Each check within a dimension scores proportionally. Example: A1 has 5 checks, each worth 2 points (total 10). A check scores 0 (fail), 1 (partial), or full points (pass).

**If >10 components:** Split into batches of 5. Dispatch background agents where env-compat supports parallel dispatch.

---

## Phase 2: Automated Testing

### 2.1 Browser-Based (if --live-url and browser MCP available)

If `mcp-accessibility-scanner` is available:
- `scan_page(url)` per route for axe-core violations
- `scan_page_matrix(url, variants=["mobile", "forced-colors", "reduced-motion", "zoom-200%"])` for variant testing
- `audit_keyboard(url)` for tab order, focus visibility, keyboard traps

If `chrome-devtools` MCP is available but not accessibility-scanner:
- Navigate to pages via `navigate_page`
- Run `evaluate_script` with axe-core injection
- Take screenshots at multiple viewport sizes

**axe-core results override static scan findings:** Where automated tools provide definitive results, they take precedence over grep-based analysis.

### 2.2 pa11y Integration (if available)

If `pa11y` is available:
```bash
npx pa11y [url] --reporter json --standard WCAG2AA
```
Parse JSON output, map violations to A1-A10 dimensions.

### 2.3 Automated Coverage Note

Automated tools catch approximately 30-57% of WCAG issues. The following CANNOT be caught by automated tools and require manual verification:
- Meaningful alt text quality (automated can detect presence, not quality)
- Keyboard trap detection in complex widgets
- Logical reading order
- Content comprehension at different zoom levels
- Whether color alone conveys information (context-dependent)
- Focus management correctness in SPAs
- Screen reader announcement quality

---

## Phase 3: Manual Checklist Verification

For each dimension, verify against WCAG 2.2 success criteria:

1. Map every finding to a specific WCAG criterion (e.g., "1.1.1 Non-text Content", "2.1.1 Keyboard")
2. Classify each check as:
   - **PASS** -- criterion satisfied with evidence
   - **FAIL** -- criterion violated with evidence
   - **CANNOT DETERMINE** -- requires manual verification (e.g., screen reader testing, cognitive assessment)
3. For CANNOT DETERMINE items, describe what manual test is needed

**WCAG Level mapping:**
- Level A (minimum): 1.1.1, 1.2.1, 1.3.1, 1.4.1, 2.1.1, 2.1.2, 2.2.2, 2.3.1, 2.4.1, 2.4.2, 2.4.3, 2.4.4, 3.1.1, 3.2.1, 3.3.1, 3.3.2, 4.1.2
- Level AA (standard target): Level A + 1.3.5, 1.4.3, 1.4.4, 1.4.10, 1.4.11, 2.4.7, 3.1.2, 3.2.3, 3.3.3, 4.1.3
- Level AAA (if `--standard AAA`): Level AA + 1.4.6 (7:1 contrast), 2.3.3, 2.4.9, 2.5.8, 3.1.5, 3.1.6

---

## Phase 4: Fix Generation (if --fix or findings exist)

For each finding, generate a specific code fix:

```
### A11Y-[NNN]: [Title]
Dimension: A[N]
WCAG: [criterion number] [criterion name]
Severity: CRITICAL | HIGH | MEDIUM
Level: A | AA | AAA
File: [path:line]
Impact: [who is affected and how]

Before:
  [code snippet showing the violation]

After:
  [code snippet with the fix applied]

Notes: [implementation considerations]
```

**Prioritization order:**
1. Legal risk (CRITICAL findings in dimensions relevant to `--legal` standard)
2. User impact (keyboard/screen reader blockers > visual issues > enhancements)
3. Effort (quick wins first within same priority tier)

If `--dry-run` flag is set: report all fixes without applying. Show before/after code for each fix.

If `--fix` flag is set:
1. **Create rollback tag:** `git tag a11y-fix-YYYY-MM-DD` before applying any changes
2. Apply all CRITICAL and HIGH fixes automatically. MEDIUM fixes are reported but not auto-applied.
3. Run verification: check that fixes don't break existing tests
4. If tests fail after a fix: revert that specific fix, keep the tag for manual rollback

**Scope guard:** Fixes touch only accessibility attributes, ARIA properties, semantic elements, CSS focus/contrast styles, and meta tags. Fixes do NOT modify business logic, data fetching, or application state.

---

## Phase 5: Report & Backlog

### 5.1 Read Stage 2 Files

Read deferred files:
```
  3. ../../shared/includes/run-logger.md      -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md      -- [READ | MISSING -> STOP]
  4. ../../shared/includes/backlog-protocol.md -- [READ | MISSING -> degraded]
```

### 5.2 Scoring

**Per-dimension scoring:** Each dimension has a max weight. Score = sum of check scores within dimension.

**Overall score:** `(total earned / total possible) * 100` — A10 excluded from score (legal risk section only, max = 76 from A1-A9).

**Critical gates (explicit pass thresholds):**
- A2 (Keyboard Navigation) < 6/12 --> automatic FAIL regardless of overall score
- A4 (Color & Contrast) < 5/10 --> automatic FAIL regardless of overall score

**Grade thresholds:**
| Grade | Score | Condition |
|-------|-------|-----------|
| A | >= 85% | All critical gates pass |
| B | 70-84% | All critical gates pass |
| FAIL | < 70% | OR any critical gate below threshold |

VERDICT mapping for run log: PASS (A or B), WARN (B with critical gate borderline), FAIL (below 70% or critical gate failure).

### 5.3 Report Output

```
ACCESSIBILITY AUDIT REPORT
===============================================
Project: [name]
Date: [ISO-8601 date]
Framework: [detected]
Component Library: [detected or "custom"]
Standard: WCAG 2.2 [AA|AAA]
Legal: [ADA Title II | EAA | Section 508 | N/A]
A11y Tooling: [detected tools or "none"]

SCORE: [N]% -- Grade [A/B/C/FAIL]
===============================================

## Critical Gate Status
  A2 (Keyboard Navigation): [PASS/FAIL] ([N]/12)
  A4 (Color & Contrast):    [PASS/FAIL] ([N]/10)

## Dimension Scores
| # | Dimension | Score | Max | Key WCAG Criteria |
|---|-----------|-------|-----|-------------------|
| A1 | Semantic HTML | [N] | 10 | 1.3.1, 4.1.2 |
| A2 | Keyboard Navigation | [N] | 12 | 2.1.1, 2.1.2, 2.4.7 |
| A3 | ARIA Patterns | [N] | 10 | 4.1.2, 4.1.3 |
| A4 | Color & Contrast | [N] | 10 | 1.4.1, 1.4.3, 1.4.11 |
| A5 | Forms & Inputs | [N] | 10 | 1.3.1, 3.3.1, 3.3.2 |
| A6 | Images & Media | [N] | 8 | 1.1.1, 1.2.1, 1.2.2 |
| A7 | Responsive & Zoom | [N] | 6 | 1.4.4, 1.4.10 |
| A8 | Motion & Animation | [N] | 5 | 2.2.2, 2.3.1, 2.3.3 |
| A9 | Reading & Content | [N] | 5 | 2.4.2, 3.1.1, 3.2.3 |
| A10 | Legal Compliance | [N] | 4 | (aggregate) |
| | **Total** | **[N]** | **80** | |

## Findings (sorted by legal risk, then user impact)

### A11Y-001: [Title]
  Dimension: A[N]
  WCAG: [criterion number and name]
  Severity: CRITICAL | HIGH | MEDIUM
  File: [path:line]
  Impact: [who is affected and how]
  Fix: [specific code change or reference to Phase 4 fix]

### A11Y-002: [Title]
  ...

## Legal Compliance Summary
| Standard | Status | Key Gaps |
|----------|--------|----------|
| WCAG 2.2 AA | [PASS / PARTIAL / FAIL] | [summary] |
| ADA Title II | [COMPLIANT / AT RISK / NON-COMPLIANT / N/A] | [summary] |
| EAA | [COMPLIANT / AT RISK / NON-COMPLIANT / N/A] | [summary] |
| Section 508 | [COMPLIANT / AT RISK / NON-COMPLIANT / N/A] | [summary] |

## Automated vs Manual Coverage
  Automated checks (axe-core/pa11y): [N issues found | "not run"]
  Static code analysis: [N issues found]
  Manual verification needed: [N items flagged as CANNOT DETERMINE]

## Per-Component Breakdown
| File | A1 | A2 | A3 | A4 | A5 | A6 | A7 | A8 | A9 | Total | Grade |
|------|----|----|----|----|----|----|----|----|----|----- -|-------|
| [path] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N] | [N]% | [A-FAIL] |
```

### 5.4 Backlog Persistence

If `--persist-backlog` is set or CRITICAL findings exist:

For each CRITICAL or HIGH finding, persist to `memory/backlog.md`:
```markdown
- B-{N} | {file}:{line} | A11Y-{NNN} | {WCAG criterion}: {description} | seen:1 | confidence:{0-100} | source:a11y-audit | {date}
```

**Dedup:** If the same `file|WCAG criterion` combo exists, increment `seen:N` and update the date.

### 5.5 Save Report

Save to: `audit-results/a11y-audit-YYYY-MM-DD.md`

### 5.6 Propose Next Actions

| Finding | Action | Command |
|---------|--------|---------|
| Critical gate A2 failure | Fix keyboard navigation | `zuvo:build fix keyboard traps in [component]` |
| Critical gate A4 failure | Fix contrast | `zuvo:build update color tokens for WCAG contrast` |
| Multiple A3 ARIA issues | Fix ARIA patterns | `zuvo:build add ARIA attributes to [component]` |
| A5 form issues | Fix form accessibility | `zuvo:build add form labels and error association` |
| No a11y tooling | Add eslint-plugin-jsx-a11y | `zuvo:build add eslint-plugin-jsx-a11y` |
| Broad failures (Grade C/FAIL) | Full multi-agent UI review | `zuvo:ui-design-team [path]` |
| DX12-DX17 also failing | Run design-review | `zuvo:design-review [path]` |

---

## Completion

After completing the audit, print:

```
A11Y-AUDIT COMPLETE
-----
Components audited: [N]
Standard: WCAG 2.2 [AA|AAA]
Score: [N]% -- Grade [A/B/C/FAIL]
Critical gates: A2=[PASS/FAIL] A4=[PASS/FAIL]
Findings: [N] CRITICAL, [N] HIGH, [N] MEDIUM
Fixes generated: [N] (if --fix)
Legal: [status summary]
Run: <ISO-8601-Z>	a11y-audit	<project>	<score>%	-	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

**Field resolution:**
- `CQ_SCORE`: `<score>%` (overall percentage)
- `Q_SCORE`: `-` (not applicable)
- `VERDICT`: `PASS` (>=85%), `WARN` (70-84%), `FAIL` (<70% or critical gate = 0)
- `TASKS`: `-`
- `DURATION`: `<N>-dimensions` (number of dimensions scored, typically 10)
- `NOTES`: `WCAG2.2-[AA|AAA] [N]-findings [legal-status]` (max 80 chars)

---

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| Keyboard traps, missing focus | Fix keyboard navigation | `zuvo:build [description]` |
| Contrast failures | Fix color tokens | `zuvo:build [description]` |
| Missing ARIA on components | Fix ARIA patterns | `zuvo:build [description]` |
| Form a11y gaps | Fix form accessibility | `zuvo:build [description]` |
| Broad design issues | Multi-agent UI review | `zuvo:ui-design-team [path]` |
| Surface-level DX checks | Design consistency audit | `zuvo:design-review [path]` |
| Security concerns surfaced | Security audit | `zuvo:security-audit [path]` |
