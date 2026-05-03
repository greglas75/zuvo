# Pipeline Defects Research — Why brainstorm/plan/execute Ships 60% Features

> **Purpose:** Evidence-based assessment of the brainstorm → plan → execute pipeline's failure modes, with per-skill breakdown, log-derived statistics, and competitor comparison.
> **Status:** RESEARCH ONLY — no skill changes proposed in this doc. Fixes go in a follow-up.
> **Author:** zuvo plugin maintenance
> **Date:** 2026-05-03
> **Scope:** skills/brainstorm, skills/plan, skills/execute, skills/build (the pipeline that ships features)

---

## TL;DR

**The pipeline reports PASS 88% of the time.** When `zuvo:review` is run later on the same code, it finds production bugs the pipeline declared "all gates green" hours earlier.

**Documented evidence (from ~/.zuvo/retros.md):**

- **2026-04-22 execute (translation-qa, word-document/codec):** `status: PASS | failure_cause=none | q_gates: 19/19 aggregate | tests: ~150 passing`
- **2026-05-01 review (same placeholder-codec code):** `status: FAIL | failure_cause=prod-bug` — `R-1 validate Set dedup bug`, `R-2 data loss in stripRedundantVoidCloses`, Q7=0 (error paths), Q11=0 (branches)

The execute pipeline missed two production data-loss bugs that a later review caught in 45 tool calls.

**For the user's current canonical-codec-storage feature**, the pattern repeated visibly: spec marks `partially implemented. Backend works, UI does not`. The execute did not lie about the backend — backend tests pass. It lied about the UI tasks because the gates it runs cannot observe a rendered DOM.

---

## Part 1 — Statistical Picture

### 1.1 PASS rate is fictional

From `~/.zuvo/runs.log` (33-day window, 2026-03-28 → 2026-04-29):

| Skill | Total runs | PASS | WARN | FAIL/MIXED |
|-------|-----------:|-----:|-----:|-----------:|
| execute | 24 | 22 | 2 | 0 |
| build | 2 | 1 | 0 | 0 (1 critical-only) |
| **TOTAL pipeline** | **26** | **23 (88%)** | **2** | **0** |

`zuvo:execute` and `zuvo:build` between them have **never declared FAIL** in 26 runs. Yet the project they ship into has a documented partial-implementation feature (canonical-codec-storage), shipped with backend complete and UI shell-only. Both states cannot be true simultaneously. The PASS verdict is structurally unable to detect the failure mode the user actually cares about.

### 1.2 Retros are silently skipped

From the same window:

- **26 execute/build sessions** in runs.log
- **Only 2 execute/build retros** in retros.log

24 of 26 (92%) pipeline sessions skip the retrospective entirely. The retrospective is the only mechanism for the pipeline to *learn* it failed. With 92% of runs producing no learning data, the pipeline has no feedback loop. Defects don't propagate back into the skill files because they're never recorded.

The phrase "RETRO: skipped (trivial session)" appears as a documented escape hatch in `skills/execute/SKILL.md`, `skills/plan/SKILL.md`, `skills/brainstorm/SKILL.md`, and `skills/build/SKILL.md`. There is no operative definition of "trivial" — it functions as opt-out.

### 1.3 Retro PASS:FAIL ratio

In retros that *do* run: **99 PASS claims vs 3 FAIL claims**. All 3 FAIL claims come from `zuvo:review`, never from `zuvo:execute` or `zuvo:build`.

### 1.4 The smoking-gun session pair

```
2026-04-22T10:25:44Z  execute  translation-qa
  status: PASS
  q_gates: 19/19 aggregate across new test files
  tests: ~150 new tests passing across 27 commits
  failure_cause: none
  notes: word_document TranslationType shipped: 27 commits, ~6100 LOC new, passthrough+UI+E2E

2026-05-01T15:12:20Z  review  translation-qa  (same codebase, placeholder-codec T1-T39)
  status: FAIL
  q_gates: 16/17 avg — Q7=0 in encode.test.ts, Q11=0 in ChipValidator
  failure_cause: prod-bug (R-1 validate Set dedup, R-2 data loss in stripRedundantVoidCloses)
  findings: 4 MUST-FIX, 6 RECOMMENDED, 4 NIT
```

The execute pipeline's `q_gates: 19/19 aggregate` reporting is misleading by construction — averaging hides per-file failures. Q7 (error paths) and Q11 (branches) were 0 in specific files, but the aggregate said 19/19.

---

## Part 2 — Per-Skill Defect Breakdown

### 2.1 `skills/execute/SKILL.md`

**What it claims to do:** Drive an approved plan to completion task-by-task with spec review, quality review, adversarial review per task.

**What it actually verifies (Step 4-7):**

| Gate | What it checks | Can it observe a running browser? |
|------|---------------|----------------------------------|
| Spec Reviewer | Code matches plan task spec | No |
| Quality Reviewer | CQ1-CQ29 + Q1-Q19 on source files | No |
| Adversarial Review | LLM diff review across providers | No |
| Verification | Shell command exit code (test runner, type checker) | No |

**The defect:** Every gate operates on **source files or process exit codes**. None can observe a rendered DOM, click an element, validate that backspace deletes a chip atomically, or check that a target column shows visual chips instead of `[[gN]]` tokens. For UI tasks, the gates can be 100% green while the feature is 0% functional.

**Specific evidence from SKILL.md:**

- Line 39: `[GATE: adversarial-done] PASS` — adversarial reviews diff text
- Line 232: `verify="pnpm vitest run src/foo.spec.ts" exit=0` — example verification is a unit test
- Line 511-515: Final completion summary lists `Verify: [command -> exit code]` with no UI verification field
- Line 643-657: `COMPLETION GATE CHECK` has 8 gates — none mention browser, screenshot, DOM, render, accessibility, or visual

**The aggregate-q-gate fraud:** `q_gates: 19/19 aggregate across new test files` (line 232 telemetry pattern) is what was logged for the codec session. Averaging across files hides per-file zeros. The review skill caught Q7=0 and Q11=0 in specific files; the aggregate said all-green.

**HARD CONTINUATION RULE conflict:** Line 241 says "After Step 9b ... IMMEDIATELY start task N+1. Do NOT estimate ... do NOT ask 'want me to continue?'". This protocol is correct for backend pipelines but explicitly forbids the natural pause point where a human (or browser test) would verify UI behavior between tasks.

### 2.2 `skills/build/SKILL.md`

**What it claims to do:** Tiered feature build for 1-5 production files.

**What it actually verifies (Phase 4):**

| Tier | Verification | UI-aware? |
|------|-------------|-----------|
| LIGHT | Tests + types (if checker exists) | No |
| STANDARD | Tests + types | No |
| DEEP | Tests + types + lint | No |

**The defect:** Same as execute. Phase 4.3 EXECUTION VERIFICATION checklist (lines 515-531) has 11 items. **Zero** are UI-related. The closest thing to a runtime check is "Tests pass" — but unit tests for a `<TargetColumn>` component pass when the component renders, not when a human can edit a chip with backspace.

**Tier escalation does not help:** Even DEEP tier does not add browser verification. DEEP only adds independent CQ Auditor + Test Quality Auditor agents — both read source files.

**Phase 4.4 Adversarial Review:** Pipes `git diff --staged` to adversarial-review. The adversarial reviewer is an LLM that reads diff text. It cannot observe behavior.

### 2.3 `skills/plan/SKILL.md`

**What it claims to do:** Decompose work into ordered TDD tasks.

**The defect (Task Authoring Rules, lines 204-215):**

- Rule 4: "The Verify step must include an exact shell command whose exit code proves the claimed invariant" → constrains verification to **shell exit codes**. A shell exit code cannot prove "user can edit chip with backspace".
- Rule 9: "Every task that creates production code must include a test file" → assumes unit tests are sufficient evidence.
- The plan template (lines 188-201) has no field for `BrowserVerify:`, `VisualCheck:`, or `UserCanDo:`.

**Plan structurally cannot ask execute to verify UI**, because the plan vocabulary doesn't include the words.

**Coverage Matrix orphaning:** Line 210 requires every Coverage Matrix row to map to a task's Acceptance field. But Acceptance is a checkbox satisfied when the task is committed. There's no separate "user can perform this" check. Acceptance criteria like "proofreader can edit chip" have no verification path other than "task committed".

### 2.4 `skills/brainstorm/SKILL.md`

**What it claims to do:** Produce an approved spec.

**The defect (Phase 3 spec template, lines 225-356):**

- "Acceptance Criteria" splits into Ship vs Success criteria (line 314-325) — good
- "Validation Methodology" (line 326) says "must be concrete: specific script, command, comparison method"
- But the **spec template has no UI evidence requirement.** No screenshot, no user-task walkthrough, no "what does the user see when this works".

**The user-facing acceptance test never gets written into the spec**, so plan can't decompose it into a task, so execute has nothing to verify for UI. The defect chains forward.

**Failure Modes table (lines 280-310):** Required for every component. But "component" in the spec means software component. Failure modes for a **user interaction** (e.g., "user clicks chip, expects atomic delete") have no row.

---

## Part 3 — Why The User Got Burned

The user's `2026-05-02-canonical-codec-storage-spec.md` documents the exact failure mode. Reading the spec's "What does NOT work today" section against the pipeline output:

| User's reality | Execute claimed |
|---------------|----------------|
| Target column shows raw `[[gN]]` tokens | Tasks committed, tests green |
| Backspace doesn't delete chip atomically | Tasks committed, tests green |
| Toolbar with insert-tag buttons not built | Tasks committed (likely deferred) |
| TM short-circuited, returns no match | Tests green (skip path tested, not user-visible TM benefit) |
| Search filter doesn't match canonical text | Tests green (unit test of filter function passed) |

Every line is a UI/UX failure. Every line passed every gate the pipeline runs. The pipeline did exactly what its definition allows. The user's frustration is correct: the verdict is meaningless for UI work.

---

## Part 4 — Competitor Comparison

> See companion file `docs/research-competitor-ui-gates.md` (in progress) for full citations. Summary below.

### 4.1 Tools that DO verify UI rigorously

| Tool | Mechanism | How it works |
|------|-----------|--------------|
| **Cline** (formerly Claude Dev) | Built-in browser tool | Agent navigates to the dev server, screenshots, clicks, reads DOM. UI verification is a first-class step, not an afterthought. |
| **Devin 2.2** | Computer use + cloud sandboxes | Devin claims "self-verifying via computer use" — actually clicks the UI it built. |
| **Cursor 3 Design Mode** | In-browser annotation | User annotates a rendered element; agent receives DOM context + screenshot. |
| **OpenAI Operator / Codex App in-app browser (Apr 2026)** | Native browser control | Visual bug repro + verification in a real browser. |
| **Bolt.new / v0.dev** | Live preview iframe | Every change updates an iframe; the model sees the rendered output before declaring done. |

### 4.2 Tools that DON'T verify UI but should

| Tool | What they do instead | Same defect as zuvo? |
|------|---------------------|---------------------|
| **Aider** | Auto-lint + auto-test loop after every edit | Yes — text-only verification. |
| **Continue.dev** agent mode | Tests + types | Yes. |
| **GitHub Copilot Workspace** | Tests + CI | Yes. |
| **CodeRabbit Agent** | Static review + tests | Yes. |
| **OpenAI Codex CLI** (no app) | Tests | Yes. |

### 4.3 Patterns to steal

From the rigorous group:

1. **Browser-as-tool primitive.** Cline's pattern: agent has `browser_action(launch|click|scroll|type|close)`. The agent must decide when to use it; for UI tasks, completion is gated on at least one round-trip. zuvo has access to `mcp__chrome-devtools__*` and `mcp__playwright__*` (visible in this session) but no skill **mandates** their use for UI work.

2. **Task-class-aware completion gates.** Devin classifies tasks by surface. UI tasks require computer-use verification; backend tasks don't. zuvo's `build` has tiers (LIGHT/STANDARD/DEEP) but the axis is risk, not surface. A new axis — "touches `.tsx`/`.vue`/`.svelte`" — would orthogonally trigger a UI gate.

3. **Visible artifact in completion summary.** Cursor 3 attaches a screenshot to every Composer turn that touches UI. The artifact makes the user's smoke-test trivial. zuvo's BUILD COMPLETE block has no place for screenshots or rendered state.

4. **"Cannot verify → cannot complete" honesty.** Bolt's iframe failing to render = task not done; the model is forced to fix the regression. zuvo's gates pass even when the iframe would be blank, because zuvo never opens the iframe.

---

## Part 5 — Per-Skill Defect Inventory (Concrete)

### 5.1 `skills/execute/SKILL.md`

| # | Defect | Evidence | Severity |
|---|--------|----------|----------|
| E1 | No UI verification gate at any step | All gates operate on text; lines 246-263 lifecycle has no browser step | CRITICAL |
| E2 | `q_gates` reported as aggregate hides per-file zeros | Line 232 telemetry; 2026-04-22 codec session q=19/19 vs review found Q7=0 Q11=0 | HIGH |
| E3 | HARD CONTINUATION RULE forbids natural pause for human verification | Lines 241-242 | HIGH |
| E4 | Completion gate checklist (lines 643-657) has zero UI items | 8 gates, all backend | CRITICAL |
| E5 | Adversarial review is text-only by design | Step 7b, line 435 | MEDIUM (acknowledged limitation) |
| E6 | RETRO opt-out via "trivial session" not defined | Line 632, 92% skip rate observed | HIGH |
| E7 | "tests pass + commit = COMPLETED" is the entire definition of done | Step 9b, line 502 | CRITICAL |

### 5.2 `skills/build/SKILL.md`

| # | Defect | Evidence | Severity |
|---|--------|----------|----------|
| B1 | Verification commands matrix (lines 503-507) has no UI option even at DEEP tier | Tier table | CRITICAL |
| B2 | Risk Signals (lines 99-108) does not include "touches UI / .tsx / component" | 7 signals listed, none UI-aware | HIGH |
| B3 | EXECUTION VERIFICATION checklist (515-531) — 11 items, 0 UI | All-text gates | CRITICAL |
| B4 | Phase 1b agents read source files only | Blast Radius Mapper, Existing Code Scanner | MEDIUM |
| B5 | BUILD COMPLETE summary (lines 624-651) has no `Visual:` or `UI verified:` field | Output template | HIGH |

### 5.3 `skills/plan/SKILL.md`

| # | Defect | Evidence | Severity |
|---|--------|----------|----------|
| P1 | Task template Verify field is constrained to "exact shell command" (rule 4, line 209) | Excludes browser action | CRITICAL |
| P2 | No task type for "user-flow verification" | Plan template lines 188-201 | HIGH |
| P3 | Coverage Matrix Acceptance maps to commit, not user-observable behavior | Lines 175-179 | HIGH |
| P4 | No splitting heuristic for backend-vs-UI in a feature | Rule 2 size limits, but no surface split | MEDIUM |
| P5 | QA Engineer agent (Phase 1.3) covers testability for code, not for users | Agent role definition | MEDIUM |

### 5.4 `skills/brainstorm/SKILL.md`

| # | Defect | Evidence | Severity |
|---|--------|----------|----------|
| BR1 | Spec template has no "User-visible behavior" or "Manual verification steps" section | Lines 232-356 | CRITICAL |
| BR2 | Failure Modes table (lines 280-310) is component-oriented, not user-oriented | Per-component scenarios required | HIGH |
| BR3 | Acceptance Criteria split is Ship vs Success — both can pass without a user touching the feature | Line 314-325 | HIGH |
| BR4 | Validation Methodology (line 326) demands a "specific script" — disallows "click X, observe Y" | Excludes manual checks | MEDIUM |
| BR5 | No mandate for screenshot/wireframe in spec for UI features | Spec structure | MEDIUM |

---

## Part 6 — Compounding: Why Defects Stack

Reading the four skills together, the defect chain is:

```
brainstorm: spec has no user-visible-behavior section
      ↓
plan:      task verify field is shell-only, AC maps to commit
      ↓
execute:   gates are spec-review + cq + adversarial + tests, all text
      ↓
result:    "27/27 PASS" with broken UI, fixed only when zuvo:review runs later
```

Each downstream skill operates on the upstream artifact's vocabulary. Brainstorm doesn't write "browser verifies", so plan can't decompose it, so execute has nothing UI-shaped to verify. Fixing only execute (e.g., adding a UI gate at the bottom) leaves plan and brainstorm able to feed it task lists with no UI tasks defined — execute would gate-pass trivially.

**Implication:** This is a four-skill fix, not a one-skill fix. The vocabulary needs to land in brainstorm's spec template first, propagate through plan's task fields, then trigger gates in execute and build.

---

## Part 7 — Tooling Already Available But Unused

In this very session, the following deferred tools surfaced:

- `mcp__chrome-devtools__navigate_page`, `take_screenshot`, `take_snapshot`, `click`, `fill`, `evaluate_script`, `wait_for`, `list_console_messages`
- `mcp__playwright__browser_navigate`, `browser_snapshot`, `browser_click`, `browser_fill_form`, `browser_take_screenshot`
- `mcp__mcp-accessibility-scanner__scan_page`, `audit_keyboard`, `browser_navigate`

**No zuvo skill loads these tools or instructs an agent to use them.** The infrastructure for UI verification is sitting unused next to the pipeline that desperately needs it.

The Anthropic Claude Code hook spec (referenced in CLAUDE.md) supports `PreToolUse` and `PostToolUse` hooks. A hook that runs after `Edit`/`Write` on a `.tsx` file and refuses to mark the task complete unless a screenshot was taken would cost ~30 lines of config — but no skill enforces it.

---

## Part 8 — Honest Limits

**What this research does NOT establish:**

- Whether *all* UI-visible defects can be caught by browser-based verification. Some require human aesthetic judgment.
- Whether running playwright/chrome-devtools in every UI task is cost-tolerable (each screenshot + DOM snapshot ≈ 1-3K tokens).
- Whether the failure rate is comparable across competitors. Cline/Devin probably have analogous defects we haven't measured.

**What this research DOES establish:**

- The pipeline structurally cannot detect UI failures.
- The user has direct evidence of this happening (canonical-codec-storage UI half-built).
- The retro skill has a 92% skip rate, so we're not learning from the failures we ship.
- The PASS verdict is granted on text-only criteria and means nothing for UI work.

---

## Part 9 — Recommended Investigation Vectors (NOT fixes, NOT to be implemented in this doc)

These are angles for a follow-up design doc, ordered by suspected leverage:

1. **Surface-aware completion gate.** Add a `[GATE: ui-verified]` requirement that triggers when a task touches `*.tsx | *.vue | *.svelte | *.astro` in a `components/` or `app/` directory. Gate is satisfied only by attached screenshot path or explicit `[GATE: ui-verified] SKIP_REASON=<text>` declaration. The skip reason is recorded in run-log so user can see it.

2. **Browser tool mandate per task class.** Plan task template gains a `Surface: backend | api | ui | mixed` field. Execute's per-task cycle has a Step 5b for `ui` tasks: open dev server, navigate to the changed route, take snapshot, post-check via the inspector tool the agent has access to.

3. **Spec template gains user-behavior section.** Brainstorm spec adds:
   ```
   ## User-Visible Behavior
   For each acceptance criterion, describe what the user sees and does.
   - AC: <id>
     User action: <click/type/etc>
     Expected: <what they observe>
     Verification: <screenshot diff | manual list step | playwright spec>
   ```

4. **Retro gate removal.** Replace "trivial session" opt-out with hard requirement: every pipeline run produces a retro entry, even if the entry is `Friction: none observed (single-task, all green)`. Brings retro coverage from 8% to 100%.

5. **Aggregate metric ban.** Forbid `q_gates: N/M aggregate` style reporting. Require per-file scores in the telemetry block. Prevents the 2026-04-22 codec scenario where 19/19 hid Q7=0 in two specific files.

6. **Borrow Cline's browser-step grammar.** When agent dispatch is available, pass a `BROWSER_TOOL_AVAILABLE=true` flag and require its use for UI tasks. When unavailable, mark task `BLOCKED: no UI verification path` rather than silently passing.

7. **Screenshot in BUILD/EXECUTE COMPLETE blocks.** Final summary attaches paths to artifacts in `.zuvo/screenshots/<task-N>.png`. User can open them in 1 second to validate.

---

## Part 10 — Direct Evidence Map

| Claim | Source |
|-------|--------|
| 88% PASS rate, 0 FAIL in 26 pipeline runs | `~/.zuvo/runs.log`, awk counts |
| 92% retro skip rate (24 of 26) | `~/.zuvo/runs.log` vs `~/.zuvo/retros.log` |
| Codec PASS-then-bug session pair | `~/.zuvo/retros.md`, sections "2026-04-22 execute translation-qa" and "2026-05-01 review translation-qa placeholder-codec-T1-T39" |
| Execute has no UI gate | `skills/execute/SKILL.md` lines 246-263, 643-657 |
| Build has no UI verification | `skills/build/SKILL.md` lines 503-507, 515-531 |
| Plan task verify is shell-only | `skills/plan/SKILL.md` line 209 |
| Spec template has no user-visible-behavior section | `skills/brainstorm/SKILL.md` lines 232-356 |
| Browser MCP tools available but unused | This session's deferred-tool list |
| User's current canonical-codec-storage state | `docs/specs/2026-05-02-canonical-codec-storage-spec.md` "What does NOT work today" |

---

*End of research. Fixes belong in a follow-up design doc; this file documents the problem, not the solution.*
