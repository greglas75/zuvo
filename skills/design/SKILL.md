---
name: design
description: >
  Intent-first UI design with conscious, traceable design decisions. Persists
  decisions in .interface-design/ for cross-session consistency. Includes domain
  exploration, design system generation (system.md + system.json), per-component
  construction with mandatory checkpoints, and craft validation tests. Modes:
  init, [component], improve [path], extract [path], status, --quick, --dry-run.
  NOT for auditing existing UI (use zuvo:design-review).
---

# zuvo:design — Intent-First Interface Design

Build UI with conscious, traceable design decisions. Every visual choice must be explainable: traced from user intent through domain exploration to specific token values. Persists decisions in `.interface-design/system.md` and `system.json` for cross-session consistency.

**Scope:** New interface creation, existing UI improvement, design system extraction, component construction within an established system.
**Out of scope:** Auditing existing UI against checklists (`zuvo:design-review`), multi-agent visual inspection (`zuvo:ui-design-team`), code quality (`zuvo:review`).

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

**Design-specific CodeSift usage:**
- `get_file_tree(repo, path_prefix="src/components/ui")` -- instant design system inventory
- `find_references(repo, symbol_name="Dialog")` -- usage patterns of UI primitives
- `search_symbols(repo, query, kind="function", file_pattern="*.tsx")` -- check for existing similar components
- `search_text(repo, query="cn\\(", file_pattern="*.tsx")` -- Tailwind composition patterns
- `assemble_context(repo, query="<component>", token_budget=4000)` -- gather component + types + imports

---

## Step 0: Parse $ARGUMENTS

| Argument | Behavior |
|----------|----------|
| `init` | Full flow: intent exploration, domain analysis, direction selection, system.md creation |
| `[component]` | Build specific component within existing design system |
| `improve [path]` | Analyze existing UI, propose unified direction, apply improvements |
| `extract [path]` | Extract implicit design patterns from existing code into a proposed system.md |
| `status` | Show current design system state |
| `--quick [component]` | Fast path: load system.md, build, auto-save. Skips craft validation but enforces minimum gates (token usage, touch targets >=44px, no hardcoded colors/spacing). |
| `--dry-run` | Preview: run all phases but do not write files. Show diff of proposed changes. Combinable with `--quick`. |

Default: `init`

---

## Step 0.5: Prerequisites Check

Run these checks before starting. Print status for each.

### Required

| Check | How | If missing |
|-------|-----|------------|
| Package.json exists | `cat package.json` | WARN -- cannot detect framework. Ask user. |
| Frontend framework | Check deps for react/next/vue/svelte/angular | WARN -- proceed with generic HTML/CSS |
| CSS framework + version | Check for tailwind.config.* (v3), @theme in CSS (v4), styled-components, CSS modules. If Tailwind: check version. | INFO -- token format adapts to detection |

### Recommended

| Check | How | If missing |
|-------|-----|------------|
| Design system library | Check deps for @shadcn/ui, @radix-ui, @mui, @mantine | INFO -- will propose from scratch |
| Existing UI files | `find src -name "*.tsx" -o -name "*.jsx" | head -1` | INFO -- fine for init. For improve/extract: STOP. |
| Dev server config | Check for next.config.*, vite.config.* | INFO -- useful for preview |

**For `improve`/`extract` mode:** no UI files = STOP.

---

## Phase 1: Context

### Step 1: Check for Existing Design System

```bash
cat .interface-design/system.md 2>/dev/null
```

**If system.md exists:**
- Read and load all tokens, patterns, decisions
- Extract `INTENT` from the Direction section
- Print: `Design system loaded: [personality], [N] tokens, [N] patterns, last updated [date]`
- `--quick` mode: go directly to Phase 4 (build), skip craft validation, auto-save
- Normal mode: skip Phase 2-3, go to Phase 4

**If system.md does NOT exist:**
- If argument is `[component]` or `--quick`: warn "No design system found. Run `zuvo:design init` first."
- If argument is `init`, `improve`, or `extract`: proceed to Phase 2

---

## Phase 2: Intent Exploration

### Step 3: Intent Questions

Present three questions. If the environment is interactive, ask inline; otherwise make the safest reasonable decision and annotate it.

**Q1: Who is the person using this?**
Not "users" -- specific context. Example: "Marketing manager reviewing campaign performance before Monday standup."

**Q2: What must they accomplish?**
Verb-based tasks, not features. Example: "Scan 20 campaigns, compare week-over-week, flag underperformers, share report."

**Q3: How should this feel?**
Offer 3-4 options based on product type:
- "Calm authority" -- quiet confidence, the user trusts the tool
- "Energetic efficiency" -- fast, snappy, dense with info
- "Warm guidance" -- approachable, helps without overwhelming
- "Precise control" -- technical, every detail accessible

Capture answers as `INTENT` for all subsequent decisions.

---

## Phase 3: Domain Exploration

### Step 4: Product Domain

Based on intent answers and project code, produce 4 outputs:

1. **Domain Concepts** (5+) -- the vocabulary and mental model of the product domain
2. **Color World** (5+) -- emotions and associations that inform palette selection
3. **Signature** (1) -- a unique design element that makes this product recognizable
4. **Defaults to Avoid** (3) -- generic patterns that would make this feel like every other product

Match the user's domain to industry patterns if applicable (SaaS Dashboard, Fintech, Healthcare, E-Commerce, Admin Panels, Data Visualization, AI/Chat, Landing Pages, Developer Tools, Onboarding). Use industry-specific layout rules, color presets, and anti-patterns as starting constraints.

Present to user for confirmation. Adjust based on feedback.

### Step 5: Design Direction

1. Select the closest design direction (or blend 2) based on intent and domain
2. Adapt tokens to the domain (do not copy presets verbatim)
3. Present proposal with: Personality, Foundation palette, Depth (elevation), Accent color, Spacing scale, Border radius system, Typography -- each tied to intent

Ask for confirmation:
- "Looks good, build it"
- "Adjust tokens" -- user specifies changes
- "Try different direction" -- restart Phase 3

---

## Phase 4: Build

### Step 6: Per-Component Construction

For EACH component, declare a mandatory checkpoint:

```
COMPONENT: [name]
  Intent:      [why this exists, what user accomplishes]
  Palette:     [which colors from system, why]
  Depth:       [which elevation level, why]
  Surfaces:    [background, border treatment, why]
  Typography:  [sizes, weights, why]
  Spacing:     [which scale values, why]
  Motion:      [transitions, tier (micro/standard/emphasis), reduced-motion fallback]
  Responsive:  [layout adaptation, content priority, touch targets, typography scaling]
```

Build the component code with these decisions applied.

**For `improve` mode:**
1. Read existing component
2. Identify defaults (generic values, inconsistent tokens)
3. Propose specific changes tied to design direction
4. Apply changes preserving functionality

**For `extract` mode:**
1. Scan all UI files in scope
2. Catalog: colors (frequency), spacing values, radius values, font sizes, motion durations, component patterns
3. Build Mutations vs Standard table: for each token category, list every variant found alongside the proposed canonical value
4. Identify implicit direction: map findings to closest design direction
5. Propose system.md + system.json based on actual usage
6. Skip Phase 5 -- extract produces a proposal, not built components. Go to Phase 6.

---

## Phase 5: Craft Validation

**Skip if `--quick` mode or `extract` mode.**

### Step 7: Run 4 Tests

After building, run ALL validation tests:

**1. Swap Test:** Replace design tokens with neutral alternatives. Does the component still communicate the intended personality? If it looks the same with generic tokens, the design is not intentional enough. (3 meaningful swaps required.)

**2. Squint Test:** Blur your mental image of the component. Is the visual hierarchy still clear? Primary action obvious? Sections distinguishable? (4 checks.)

**3. Signature Test:** Is the unique design element from Step 4 present? Count touchpoints across the component. (5 touchpoints required.)

**4. Token Test:** Trace every visual value back to a design token. No magic numbers, no hardcoded hex values, no arbitrary spacing. (Track traceable vs total.)

Print pass/fail for each with evidence. **If ANY test fails, iterate before showing to user.**

**Persist gate:** At least 3/4 craft tests must PASS before proceeding. If <3 pass after iteration, warn user and require explicit approval.

### Step 7.5: Save Craft Validation Report

Save to `.interface-design/craft-validation-[YYYY-MM-DD].md` with per-test results and per-component checkpoints.

---

## Phase 6: Persist

### Step 8: Save Design System

**`--dry-run`:** Print proposed diff, do not write files. End here.

**`--quick`:** Print brief diff (max 10 lines), auto-save.

**Normal mode:** After user approves:

1. Create `.interface-design/` directory
2. Generate `system.md` with all sections: Direction, Domain, Tokens, Motion, Patterns, Decisions
3. Generate `system.json` alongside -- machine-readable artifact for `zuvo:design-review`

Ask for confirmation:
- "Save" -- persist for future sessions
- "Save + commit" -- save and create git commit
- "Skip" -- do not save

If `.interface-design/` NOT in .gitignore, ask if user wants to track in git.

### Step 9: Post-Design Recommendation

Suggest running `zuvo:design-review` on the built components for a structured DX1-DX20 audit.

---

## `status` Mode

1. Check for `.interface-design/system.md`
2. If exists: print Personality, Foundation, Depth, Token count, Pattern count, Decision count, Last updated
3. If not exists: "No design system found. Run `zuvo:design init` or `zuvo:design extract [path]`."

---

## Contract: zuvo:design <-> zuvo:design-review

This skill produces two artifacts in `.interface-design/`:

| Artifact | Purpose |
|----------|---------|
| `system.md` | Human-readable design system (direction, domain, tokens, patterns, decisions) |
| `system.json` | Machine-readable for programmatic token matching |

`zuvo:design-review` reads JSON first for stable token comparison, falls back to MD if JSON missing.

| Section | Consumed by design-review |
|---------|--------------------------|
| Direction / Intent | Craft validation context |
| Domain / Signature | Signature test (5 touchpoints) |
| Tokens | DX2/DX3/DX4 enrichment |
| Motion | Cross-view motion audit |
| Patterns | DX20 enrichment |
| Domain / Avoid | Check implementation avoids listed defaults |

**No artifacts:** `zuvo:design-review` runs purely structural (DX1-DX20).
**With artifacts:** adds craft validation + intent-aware token matching.

---

## Execution Notes

- Present results, not process. Do not narrate exploration steps.
- Suggest and ask. Explore, recommend, present options. Never dictate without user input.
- Every choice traceable. If asked "why this color?" trace to intent -> domain -> token.
- Build for the detected stack. Adapt to what exists in the project.
- When improving existing UI, preserve all functionality. Only change visual/interaction design.
