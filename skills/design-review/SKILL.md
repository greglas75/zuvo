---
name: design-review
description: >
  UI/UX design consistency audit. Code-based DX1-DX20 checklist covering states,
  consistency, accessibility, responsive behavior, and interaction patterns.
  Optional visual audit via chrome-devtools screenshots and automated WCAG
  accessibility via axe-core. DAP1-DAP12 anti-pattern detection. Modes: [path],
  visual, --fix-critical, --dry-run, --max-files, --quick, loop. NOT for code
  quality (use zuvo:code-audit) or test quality (use zuvo:test-audit).
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # find component dirs, theme files
    - get_file_outline
    - search_text              # className=, design tokens, CSS variables
    - search_symbols           # component discovery
    - get_symbol
    - search_patterns          # DAP anti-patterns (inconsistent spacing, etc.)
    - audit_scan
    - scan_secrets             # env-var leaks in client code
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_image_audit, astro_svg_components]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders, trace_component_tree]
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

# zuvo:design-review — UI/UX Design Consistency Audit

Audit frontend views for design consistency, state completeness, accessibility, and interaction patterns. Two modes: code-based (grep + read, fast) and visual (chrome-devtools screenshots + axe-core WCAG audit, slower).

**Scope:** Frontend view health, design system adoption, state coverage, a11y compliance, responsive behavior.
**Out of scope:** Code quality (`zuvo:code-audit`), test quality (`zuvo:test-audit`), creating new designs (`zuvo:design`), qualitative multi-agent review (`zuvo:ui-design-team`).

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
  3. ../../shared/includes/run-logger.md -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## MANDATORY TOOL CALLS — Design Review Validity Gate

**INVALID if any tool below is skipped.** "DEFERRED", "N/A" NOT valid reasons.

| Tool | Trigger | Skip allowed? |
|------|---------|---------------|
| `get_file_tree` | Always | **NO** — find component dirs, theme files |
| `search_text` | Always | **NO** — className=, design tokens, CSS variables |
| `search_symbols` | Always | **NO** — component discovery |
| `search_patterns` | Always | **NO** — DAP anti-patterns |
| `scan_secrets` | Always | **NO** — env-var leaks in client code |
| `audit_scan` | Always | **NO** — compound check |
| React tools (analyze_renders, analyze_hooks, trace_component_tree) | React detected | **NO** when React |

Forbidden: same (skipped/N/A/codesift unavailable when deferred — REJECTED).

POSTAMBLE: report on disk → retro appended → `~/.zuvo/append-runlog` exit 0. Every DX/DAP finding needs `path/to/file.ext:LINE` (verify-audit gate).

```
Mandatory-tools-acknowledgment: I will run get_file_tree + search_text + search_symbols + search_patterns + scan_secrets + audit_scan + React tools (when React) for this design review. Every DX/DAP finding will cite a `path/to/file.ext:LINE` resolving in the current tree.
```

**Use the deterministic preload helper FIRST.** Run `~/.zuvo/compute-preload design-review "$PWD"`. Math gate enforced.

---

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Design-review CodeSift usage:**
- `get_file_tree(repo, path_prefix="src/components/ui")` -- UI component inventory with symbol counts
- `find_references(repo, symbol_name="Button")` -- shared component adoption rate
- `search_text(repo, query="aria-|role=", regex=true, file_pattern="*.tsx")` -- a11y attribute scan
- `search_text(repo, query="className=.*\\[", regex=true, file_pattern="*.tsx")` -- Tailwind magic values

---

## Step 0: Parse $ARGUMENTS

| Argument | Behavior |
|----------|----------|
| _(empty)_ | Audit all frontend views in src/ (auto-discover) |
| `[path]` | Audit views in specific directory |
| `[file]` | Audit single component (deep mode) |
| `visual` | Enable visual audit via chrome-devtools (requires running dev server) |
| `--quick` | DX checklist only, skip cross-view analysis |
| `--fix-critical` | After audit, auto-fix critical gate failures (DX6/DX7/DX10/DX20) |
| `--dry-run` | With --fix-critical: show planned edits without applying |
| `--max-files [N]` | Cap audit to N files (default: 30) |
| `--url [url]` | Dev server URL for visual audit (default: http://localhost:3000) |
| `loop` | Full cycle: audit, fix critical, re-audit quick, print delta |
| `--from-ui-team` | Skip visual re-scan (already captured), focus on DX1-DX20 code scoring |

Default: all views, code-only, with cross-view analysis.

---

## Step 0.5: Prerequisites Check

### Required (all modes)

| Check | How | If missing |
|-------|-----|------------|
| Frontend files exist | `find src -name "*.tsx" -o -name "*.jsx" -o -name "*.vue" | head -1` | STOP -- "No frontend files found." |
| Package.json exists | `cat package.json` | WARN -- cannot detect design system |

### Required (visual mode only)

| Check | How | If missing |
|-------|-----|------------|
| chrome-devtools MCP | Check whether chrome-devtools tooling is available | Skip visual, run code-only audit |
| Dev server running | `curl -sI [url] | head -1` | STOP -- suggest: `npm run dev` |

### Optional

| Check | How | If missing |
|-------|-----|------------|
| mcp-accessibility-scanner | Check whether accessibility-scanner tooling is available | DX15-DX17 use manual ARIA grep |
| Tailwind config | `cat tailwind.config.* 2>/dev/null` | DX2-DX4 token checks adapt |
| Design system artifacts | `cat .interface-design/system.json 2>/dev/null` | Structural-only audit (no craft validation) |

---

## Phase 1: Discovery

### Step 1: Detect Design System

Auto-detect from project signals:

| Signal | Design System |
|--------|--------------|
| `@shadcn/ui` or `components/ui/` with shadcn pattern | shadcn/ui |
| `@radix-ui/*` in deps | Radix UI |
| `@mui/material` in deps | Material UI |
| `@mantine/core` in deps | Mantine |
| `@chakra-ui/react` in deps | Chakra UI |
| `@headlessui/react` in deps | Headless UI |
| None + `components/` dir | Custom components |
| None + no shared components | **No design system** -- flag as DX20 |

Also detect CSS framework (Tailwind, CSS Modules, CSS-in-JS, CSS Variables).

**Next.js boundary detection:** If Next.js App Router detected, scan for co-located `loading.tsx`/`error.tsx` files alongside `page.tsx`. Pages with boundaries score DX6/DX7=1 automatically. Track as `BOUNDARY_MAP`.

Report: `DESIGN SYSTEM: [name] | CSS: [name] | SHARED: [path] ([N] components)`

### Step 2: Discover Frontend Views

Find page-level and feature-level components. Classify as PAGE (route-level), FEATURE (>100 lines with data/state), or SHARED (reusable).

If >30 views (or `--max-files` limit), audit top files by size, capped at limit.

---

## Phase 2: Code Audit (DX1-DX20)

### DX Checklist

| # | Check | Critical Gate |
|---|-------|---------------|
| DX1 | Layout structure (flex/grid, no absolute hacks) | No |
| DX2 | Color values from design tokens | No |
| DX3 | Spacing values from scale | No |
| DX4 | Typography from type scale | No |
| DX5 | Component composition (slots, not prop drilling) | No |
| DX6 | Loading state present for async operations | YES |
| DX7 | Error state present with recovery action | YES |
| DX8 | Empty state present for collections | No |
| DX9 | Success/confirmation feedback for mutations | No |
| DX10 | Destructive actions require confirmation | YES |
| DX11 | Form validation with inline errors | No |
| DX12 | Keyboard navigation for interactive elements | No |
| DX13 | Responsive behavior (mobile breakpoints) | No |
| DX14 | Focus management (visible focus rings) | No |
| DX15 | ARIA roles on interactive elements | No |
| DX16 | Color contrast (text: 4.5:1, UI: 3:1) | No |
| DX17 | Screen reader announcements for dynamic content | No |
| DX18 | Consistent interaction patterns across views | No |
| DX19 | Animation/transition timing consistent | No |
| DX20 | Uses shared component library (not one-off implementations) | YES |

Score: 1 = YES, 0 = NO, N/A with justification. N/A excludes from denominator.

**Thresholds:** PASS >= 80%, CONDITIONAL 70-79%, FAIL < 70%.

### Step 3: Batch Code Analysis

Run grep commands across the codebase for:
- ARIA attributes and roles
- Hardcoded color values (hex outside tokens)
- Magic spacing values (arbitrary px/rem)
- Loading/error/empty state patterns
- Confirmation dialog usage
- Focus ring styles

Store as `PROJECT_CONTEXT` for per-view scoring.

### Step 4: Per-View Audit

For each view, read the full component and evaluate DX1-DX20.

**If >8 views:** Split into batches of 4 and dispatch background agents where possible. Each agent receives the PROJECT_CONTEXT and scores independently.

Output per view:
```
### [file path]
View type: [PAGE/FEATURE]
DX: DX1=[0/1/NA] ... DX20=[0/1/NA]
Applicable: [N]/20 | Passed: [N] | Score: [%]
Critical gate: DX6=[0/1/NA] DX7=[0/1/NA] DX10=[0/1/NA] DX20=[0/1/NA] -- [PASS/FAIL]
Evidence (critical gates = 1): [DX=evidence pairs]
Anti-patterns: [DAP IDs or "none"]
Tier: [A/B/C/D]
Top 3 issues: [description]
```

### DAP Anti-Patterns

Check for these common UI anti-patterns during scoring:

| ID | Anti-Pattern | Detection |
|----|-------------|-----------|
| DAP1 | Prop drilling through 3+ levels | Count prop pass-through depth |
| DAP2 | Inline styles overriding design system | `style={{` next to className |
| DAP3 | Inconsistent button hierarchy (multiple primary CTAs) | Count primary-styled buttons per view |
| DAP4 | Missing disabled state on form submit | Button without disabled prop during async |
| DAP5 | Toast/notification without timeout or dismiss | Notification without auto-dismiss logic |
| DAP6 | Modal without escape-to-close | Dialog without onEscapeKeyDown or equivalent |
| DAP7 | Infinite scroll without loading indicator | Scroll listener without skeleton |
| DAP8 | Hard-coded breakpoint values | px media queries instead of theme tokens |
| DAP9 | Z-index wars (arbitrary values) | z-index values not from a defined scale |
| DAP10 | Color used as sole differentiator | Status/state communicated only by color |
| DAP11 | Duplicate component (same purpose, different implementation) | Cross-view comparison |
| DAP12 | Missing reduced-motion support | Animations without prefers-reduced-motion |

### Step 5: Cross-View Analysis

After per-view scoring, check cross-cutting concerns:

1. **Component consistency** -- same purpose, different implementations?
2. **State coverage matrix** -- view x state (loading/error/empty/success). Gaps?
3. **Off-scale values** -- count from Step 3 greps
4. **Icon library inventory** -- >1 library = flag
5. **Shared component adoption rate** -- percentage using shared components

### Step 5.5: Craft Validation (design system artifacts exist)

Read `.interface-design/system.json` (preferred) or `.interface-design/system.md` (fallback). Run 4 Craft Validation Tests:

1. **Swap Test:** Replace tokens with neutrals. Does personality survive?
2. **Squint Test:** Is hierarchy clear when blurred?
3. **Signature Test:** Is the unique element present (5 touchpoints)?
4. **Token Test:** Do actual values match declared tokens?

No system artifacts = skip.

---

## Phase 3: Visual and Accessibility Audit (visual mode only)

Requires: dev server running, chrome-devtools MCP available.

### 3.1 Screenshots

Capture at 3 breakpoints (1440, 768, 375) via chrome-devtools.

### 3.2 WCAG Accessibility Scan

If mcp-accessibility-scanner available:
- `scan_page` per route for axe-core violations
- `scan_page_matrix` for variant testing (mobile, forced-colors, reduced-motion, zoom-200%)
- `audit_keyboard` for tab order, focus visibility, keyboard traps

**axe-core results override grep-based checks:** DX15-DX17 scores come from axe-core when scanner ran.

### 3.3 Computed Styles

Color and font inventories, ARIA attribute verification.

### 3.4 Cross-View Visual Comparison

Consistency analysis across captured screenshots.

If chrome-devtools unavailable: skip entire Phase 3 with message.

---

## Phase 4: Report

### Step 7: Aggregate Results

Combine per-view DX scores + cross-view analysis + visual audit (if run) + craft validation (if run).

### Report Sections

1. **Header** -- project, date, design system, CSS framework, mode
2. **Executive Summary** -- average score, critical gate status, tier distribution
3. **Critical Gate Summary** -- DX6/DX7/DX10/DX20 per view
4. **State Coverage Matrix** -- views x states (loading/error/empty/success)
5. **Per-View Scores** -- DX1-DX20 per view with tier
6. **Cross-View Analysis** -- consistency findings
7. **Anti-Pattern Summary** -- DAP occurrences across views
8. **Craft Validation Results** (if system artifacts exist)
9. **Action Plan** -- prioritized: critical gates -> consistency -> state gaps -> design system gaps
10. **Accessibility Summary** (if visual mode ran)

Save to: `audit-results/design-review-YYYY-MM-DD.md`

### Step 9: Propose Next Actions

**If Tier D OR no design system OR DX20 widespread FAIL:**
1. "Run `zuvo:design extract [path]`" -- formalize implicit patterns
2. "Fix critical gate failures only"
3. "Fix specific view"
4. "Skip -- keep report"

**Otherwise (Tier A-C with design system):**
1. "[Best action from audit]"
2. "Fix critical gate failures only"
3. "Fix specific view"
4. "Skip -- keep report"

---

## Phase 5: Auto-Fix Critical (if --fix-critical)

**Scope guard (NON-NEGOTIABLE):** Auto-fix touches ONLY the UI/states layer -- loading wrappers, error boundaries, confirmation dialogs, component imports. **Never modify business logic, data fetching, or event handlers.**

**`--dry-run`:** List planned edits without applying.

For each critical gate failure:

| Gate | Fix |
|------|-----|
| DX6=0 | Next.js App Router? Create loading.tsx. Otherwise: wrap with loading state. |
| DX7=0 | Next.js App Router? Create error.tsx. Otherwise: wrap with error state. |
| DX10=0 | Replace destructive onClick with confirmation dialog. |
| DX20=0 | Replace one-off component with shared library equivalent. |

After applying: re-run DX scoring on fixed views to verify gates pass.

---

## Phase 6: Loop Mode (loop argument)

1. **Audit:** Full audit (Phase 1-4) -- baseline scores
2. **Fix:** Apply critical fixes (Phase 5)
3. **Re-audit:** Quick mode -- post-fix scores
4. **Delta summary:**

```
DESIGN LOOP DELTA
  Before: Avg [X]% | Critical gates: [N] FAIL
  After:  Avg [Y]% | Critical gates: [N] FAIL
  Delta:  +[Z]% | [N] gates fixed
  Remaining: [top 3 unfixed issues]
  Next step: [recommendation]
```

---

## Contract: zuvo:design <-> zuvo:design-review

This skill reads design system artifacts produced by `zuvo:design`:
- `system.json` (preferred) -- machine-readable, stable token matching
- `system.md` (fallback) -- human-readable, craft validation context

No artifacts = purely structural audit (DX1-DX20 only).
With artifacts = adds craft validation + intent-aware token matching.

---

## Completion

After completing the audit, print:

```
DESIGN-REVIEW COMPLETE
-----
Views audited: [N]
Avg DX score:  [N]%
### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  required_tool_calls:
    get_file_tree: [<N> | NOT_CALLED]
    search_text: [<N> | NOT_CALLED]
    search_symbols: [<N> | NOT_CALLED]
    search_patterns: [<N> | NOT_CALLED]
    scan_secrets: [<N> | NOT_CALLED]
    audit_scan: [<N> | NOT_CALLED]
    react_tools: [<result> | not_required | NOT_CALLED]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED]
    verify_audit_pass: [yes(<verified>/<total>) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL]
```

If `gate_status = FAIL` → VERDICT = INCOMPLETE. Append the Run line via the retro-gated wrapper (NOT direct `>> runs.log`):

```bash
echo -e "$RUN_LINE" | ~/.zuvo/append-runlog
```

Run: <ISO-8601-Z>	design-review	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use `N-dimensions` (number of DX dimensions scored, typically 20).

---

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| DX6/DX7 State incompleteness | Fix component states | `zuvo:design [component] improve` |
| DX15-DX17 Accessibility violations | Fix a11y | Direct WCAG compliance fix |
| DX13 Responsive missing | Fix responsive | `zuvo:design [component] improve` |
| 3+ DX failures in same component | Full multi-agent review | `zuvo:ui-design-team [path]` |
| DAP anti-patterns found | Refactor component | `zuvo:refactor [component]` |
| No design system detected | Bootstrap design system | `zuvo:design extract [path]` |
