---
name: ui-design-team
description: >
  Multi-agent UI review with 4 specialist perspectives: UX Researcher, Visual
  Designer, i18n/Multilingual QA, and Accessibility/Performance Auditor. Each
  agent scores independently from their expertise. Lead Designer synthesizes
  into prioritized fixes with exact code. Works with any stack: React, Astro,
  vanilla HTML/CSS, Tailwind, CSS-in-JS. Flags: [file/path], --screenshot,
  --mobile, --fix.
---

# zuvo:ui-design-team — Multi-Agent UI Review

Runs 4 specialist analyses to review a UI component or page. Each agent scores from its area of expertise. The Lead Designer synthesizes findings into a prioritized fix list with exact code for the detected stack.

**Scope:** Deep qualitative review of a specific component, page, or layout from UX, visual design, i18n, and accessibility perspectives.
**Out of scope:** Codebase-wide consistency audit (`zuvo:design-review`), design system creation (`zuvo:design`), code quality (`zuvo:review`).

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

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**UI-specific CodeSift usage:**
- `find_references(repo, symbol_name="<ComponentName>")` -- find all views using the component
- `get_file_outline(repo, file_path)` -- component structure without reading full file
- `search_text(repo, query="<token_name>", file_pattern="*.tsx")` -- token usage patterns

---

## Step 0: Parse $ARGUMENTS

| Argument | Behavior |
|----------|----------|
| _(empty)_ | Review the component/page currently in context (or ask if ambiguous) |
| `[file/path]` | Review specific component file or directory |
| `--screenshot` | Capture chrome-devtools screenshot BEFORE agents (provides visual context) |
| `--mobile` | Focus on 375px (mobile) viewport -- agents score mobile-first |
| `--fix` | After report, Lead Designer applies top 3 priority fixes immediately |

Default: review component in context, report only.

## Step 0.1: Auto-Detect Stack

Before running agents, detect the project's styling approach:

```
Check for these files (in order):
1. tokens.ts / tokens.js / design-tokens.*         -> STACK = "css-in-js-tokens"
2. tailwind.config.*                                -> STACK = "tailwind"
3. astro.config.* (check for Tailwind plugin)       -> STACK = "astro-tailwind"
4. Only .html + .css files                          -> STACK = "vanilla"
5. styled-components or emotion in package.json     -> STACK = "css-in-js"
```

Also detect:
- **Framework:** React / Astro / vanilla / Next.js
- **Token file location:** grep for `export const colors` or `--color-` in CSS
- **Component pattern:** function components / Astro components / HTML templates
- **Existing breakpoints:** grep for `@media` or Tailwind `md:` / `lg:` usage

Store detection results -- agents reference them for stack-specific guidance.

---

## Step 1: Gather Context

1. Read the component/page code being reviewed
2. Read token/theme file (if detected) -- agents need actual values
3. Read project AGENTS.md or CLAUDE.md (if either exists) -- project-specific conventions
4. Screenshot if `--screenshot` or if chrome-devtools available (375px + 1024px)
5. Note the component type: page, component, layout, widget, dashboard, form

---

## Step 2: Dispatch 4 Specialist Agents

Each agent receives: source code, detected stack info, token file contents, screenshots (if available).

In environments supporting parallel dispatch (Claude Code, Codex, Cursor 3+), run all 4 simultaneously per `env-compat.md` dispatch patterns. In sequential environments (Cursor <3.0), execute each agent's analysis in order.

### Agent 1: UX Researcher

**Focus areas and scoring (1-5 each):**

**Cognitive Load:**
- Information hierarchy clear? Primary action obvious within 2 seconds?
- How many competing visual elements?
- Flow linear and predictable?

**Interaction Quality:**
- Taps/clicks to complete primary task
- Unnecessary scrolling?
- Feedback on every action (visible response)
- Error recovery: undo/go-back available?

**Mobile Usability (375px):**
- One-thumb operable?
- Horizontal scroll?
- Touch targets >= 44x44px with >= 8px gaps?
- Input zoom prevention (font-size >= 16px on mobile inputs)?

**Performance Perception:**
- Loading states present?
- Transitions under 300ms?
- Content layout shift risk?

**Output:** Score per category, top 3 critical issues (file:line), concrete behavioral fix per issue, one thing done well.

### Agent 2: Visual Designer

Adapt token audit to detected stack:

**css-in-js-tokens:** All values MUST come from token file. Flag every hardcoded value.
**tailwind:** Check config for custom theme. Flag inline styles and arbitrary values with standard equivalents.
**vanilla:** Check for CSS custom properties. If they exist, values should reference them. If not, recommend creating a :root system.
**css-in-js (no tokens):** Flag inconsistent values. Same value in 3+ places = needs a constant.

**Scoring areas (1-5 each):**

**Token/Variable Compliance:**
- All colors from tokens/theme?
- All spacings on a consistent scale?
- All font sizes from defined scale?
- Shadows, radii, transitions consistent?

**Visual Hierarchy:**
- Clear primary action per viewport?
- Heading sizes step down logically?
- Whitespace balanced?
- Visual grouping clear?

**Interaction States:**
Every interactive element must have: default, hover, active/pressed, focus-visible, disabled. Focus ring visible and contrasting (>= 2px). Transitions 150-300ms, ease-out. Loading/skeleton state for async.

**Spacing Rhythm:**
- Consistent vertical rhythm (4px or 8px grid)
- Horizontal padding consistent within component
- Label-to-input spacing consistent

**Output:** Score per category, every hardcoded value with exact replacement (`file:line | CURRENT: value | FIX: token/class`), top 3 visual issues with exact fix values.

### Agent 3: i18n and Multilingual QA

Test mentally with benchmark strings:
- Polish: "Zdecydowanie sie nie zgadzam" (32 chars)
- German: "Stimme ueberhaupt nicht zu" (25 chars)
- Arabic: RTL, wider glyphs
- Japanese: CJK width (7 chars)
- Thai: needs line-height >= 1.8

**Scoring areas (1-5 each):**

**Text Overflow:**
- Fixed-width containers clip text?
- Flex containers wrap gracefully?
- Buttons/chips grow or clip?
- Behavior at 150% (German) AND 50% (CJK)?

**RTL Support:**
- Logical properties used? (`margin-inline-start` vs `margin-left`, Tailwind `ms-` vs `ml-`)
- Layout mirrors with dir="rtl"?
- Directional icons flipped for RTL?
- Text alignment: `start` vs `left`?

**Character Sets and Typography:**
- Font stack covers Arabic, Thai, Devanagari, CJK?
- Line-height sufficient for all scripts?
- Character count validations byte-safe for multi-byte?

**Hardcoded Strings:**
- User-visible text not from i18n/props/content?
- Labels, placeholders, error messages externalized?
- aria-label values translatable?

**Output:** Score per category, top 3 i18n-breaking issues with specific language + viewport width, CSS/layout fix per issue, list of hardcoded strings.

### Agent 4: Accessibility and Performance Auditor

**Accessibility scoring (1-5 each):**

**Semantic HTML and ARIA:**
- Correct roles on interactive elements?
- aria-checked/selected/expanded updated on state change?
- Form groups with aria-labelledby?
- Dynamic changes announced (aria-live)?
- Logical heading hierarchy?

**Keyboard Navigation:**
- Every interactive element reachable via Tab?
- Tab order matches visual order?
- Arrow keys within groups (radio, tabs, menu)?
- Enter/Space activate correctly?
- Visible focus indicator on every focusable element?
- Escape closes modals/dropdowns?

**Visual Accessibility:**
- Text contrast >= 4.5:1? Large text >= 3:1?
- UI element contrast >= 3:1?
- Information by color alone?
- Works at 200% zoom?
- >= 8px between touch targets?

**Performance scoring (1-5 each):**

**Bundle Impact:**
- React: heavy library imports?
- Astro: client:load vs client:visible?
- All: image optimization (srcset, lazy loading)?

**Render Performance:**
- Layout shifts (missing width/height on images)?
- Repaint-heavy animations (use transform/opacity)?
- Unnecessary re-renders (React: missing memo, deps array)?

**Core Web Vitals Risk:**
- LCP: largest above-fold element loaded efficiently?
- CLS: elements shift after paint?
- INP: heavy event handlers on interactive elements?

**Output:** Score per category, WCAG violations with criterion number, performance issues with fix, top 3 critical fixes.

---

## Step 3: Synthesize (Lead Designer)

### 1. Summary Table

```
                    UX    Visual  i18n   A11y   Perf   AVG
Category 1          ?/5
Category 2                 ?/5
Category 3                         ?/5
Category 4                                ?/5
Category 5                                       ?/5
OVERALL             ?      ?      ?      ?      ?     ?/5
```

### 2. Systematic Issue Detection

If 3+ agents flag the same concern type:

```
SYSTEMATIC ISSUES DETECTED
  [N] agents flagged [issue type] across [component]
  Recommendation: Run zuvo:design-review [path] for structured DX1-DX20 audit.
```

Do NOT auto-invoke zuvo:design-review. This skill is qualitative (agent perspectives); design-review is quantitative (DX scores). The user decides.

### 3. Prioritized Fix List

**P0 -- BLOCKING (fix before commit):**
Issues flagged by >= 2 agents, any WCAG A violation, any layout break at 375px. Each fix includes exact code for detected STACK.

**P1 -- IMPORTANT (fix this PR):**
Single-agent issues affecting usability or consistency. Each fix includes exact code.

**P2 -- BACKLOG:**
Nice-to-have improvements. Description only.

### 4. Generate Code Fixes

Adapt to detected STACK:

**css-in-js-tokens:**
```typescript
// BEFORE (line XX):
padding: '16px',
// AFTER:
padding: spacing[4],
```

**tailwind:**
```html
<!-- BEFORE: -->
<div style="padding: 16px" class="bg-[#f1f5f9]">
<!-- AFTER: -->
<div class="p-4 bg-slate-100">
```

**vanilla CSS:**
```css
/* BEFORE: */
.card { padding: 16px; background: #f1f5f9; }
/* AFTER: */
:root { --spacing-4: 1rem; --color-surface: #f1f5f9; }
.card { padding: var(--spacing-4); background: var(--color-surface); }
```

### 5. Apply Fixes

If `--fix` flag: apply the top 3 P0 fixes directly. Otherwise: present the fix list for review.

After applying fixes, if browser tools available, capture verification screenshots at 375px and 1024px.

---

## Abbreviated Mode (Quick Check)

For small changes, skip full 4-agent review. Run inline self-check:

```
Before committing any UI change, verify:
[ ] All values from tokens/theme (no hardcoded hex/px/rem)
[ ] Touch target >= 48px on interactive elements
[ ] Works at 375px without horizontal scroll
[ ] Focus ring visible on interactive elements
[ ] aria-label or aria-labelledby on interactive elements
[ ] Text survives 150% longer label (German test)
[ ] No hardcoded user-visible strings
[ ] Images have width/height (no CLS)
[ ] Transitions <= 300ms, using transform/opacity
```

---

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| Systematic issues (3+ agents) | Structured DX audit | `zuvo:design-review [path]` |
| No design system | Bootstrap design system | `zuvo:design extract [path]` |
| Token compliance < 3/5 | Formalize tokens | `zuvo:design init` |
| A11y score < 3/5 | Accessibility remediation | Direct fix with WCAG reference |
| i18n score < 3/5 | i18n infrastructure | Direct fix (logical properties, i18n keys) |
| Multiple P0 issues | Full redesign | `zuvo:design improve [path]` |

---

## Run Log

Log this run to `~/.zuvo/runs.log` per `{plugin_root}/shared/includes/run-logger.md`:
- SKILL: `ui-design-team`
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: PASS if review complete
- TASKS: number of components reviewed
- DURATION: `-`
- NOTES: scope summary (max 80 chars)
