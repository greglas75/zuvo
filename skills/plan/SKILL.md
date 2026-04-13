---
name: plan
description: "Analyzes architecture, selects patterns, assesses testability, then decomposes work into ordered TDD tasks with exact verification commands and explicit acceptance mapping. Works from an approved spec (zuvo:brainstorm output) or directly from a user-provided description."
---

# zuvo:plan

Create a detailed, task-by-task implementation plan. Every task follows the TDD protocol: RED (failing test) -> GREEN (minimal code) -> Verify -> Commit.

---

## Input Resolution

Determine the planning input. Two modes: **spec-driven** (from brainstorm output) or **inline** (from user description).

### Step 1: Look for a spec

1. If the user provided an explicit path (e.g., `zuvo:plan docs/specs/my-spec.md`), use that file
2. Otherwise, search: `Glob("docs/specs/*-spec.md")`
3. If multiple specs exist, present the list and ask the user which one to plan against

### Step 2: Determine mode

- **Spec found with `status: Approved`** → **spec-driven mode**. Read spec in full. This is the source of truth.
- **Spec found without `status: Approved`** → Print: "Spec exists but is not approved. Using it as reference in inline mode." Treat spec as context, not authority. → **inline mode**.
- **No spec found** → **inline mode**.

### Inline mode requirements

The user's message (argument to `zuvo:plan`) IS the planning input. Extract:
- **Goal:** what they want built
- **Scope:** which files/areas are affected (explore codebase if not stated)
- **Constraints:** any stated requirements

If the user's description is too vague to plan against (less than one sentence, no clear deliverable), ask ONE clarifying question. Do not block — a couple of sentences is enough to plan from.

Set `planning_mode: "inline"` or `planning_mode: "spec-driven"` — this affects the plan document header and review phase.

---

## Artifact Detection

Check if a plan already exists:

1. `Glob("docs/specs/*-plan.md")` — look for existing plans
2. **Spec-driven mode:** match by `spec_id` field. If a matching plan exists, ask the user whether to revise or start fresh.
3. **Inline mode:** skip this check (no spec_id to match against)
4. If no plan exists, proceed to Phase 1

---

## Mandatory File Loading

### Phase 0 — Bootstrap (load before any work)

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md  -- READ/MISSING
  2. ../../shared/includes/env-compat.md       -- READ/MISSING
  3. ../../shared/includes/quality-gates.md    -- READ/MISSING
  4. ../../shared/includes/tdd-protocol.md     -- READ/MISSING
  5. ../../shared/includes/session-state.md    -- READ/MISSING
  6. ../../rules/file-limits.md                -- READ/MISSING
  7. ../../shared/includes/run-logger.md       -- DEFERRED (completion)
  8. ../../shared/includes/retrospective.md    -- DEFERRED (completion)
```

Resolve these paths relative to the currently loaded `skills/plan/SKILL.md`. If a Phase 0 file read fails, mark it as `MISSING`. Deferred files are loaded when their phase begins, not at startup.

**If 1-2 files missing:** Proceed in degraded mode. Note which files are unavailable in the final output.
**If 3+ files missing:** Stop. The plugin installation is incomplete.

Execute the CodeSift setup procedure from `codesift-setup.md`. Note the repo identifier for agent dispatches when CodeSift is available.

---

## Phase 1: Architecture Analysis

Dispatch 3 agents SEQUENTIALLY. Each agent receives the output of the previous agent(s) as input context. The 4th step is performed by you (the main agent) as Team Lead synthesis.

The sequential order is mandatory because each agent's analysis depends on what came before: the Architect maps the terrain, the Tech Lead makes decisions based on that map, and the QA Engineer assesses testability of those decisions.

Pass the prior reports in full when practical. If you must compress for token budget, preserve concrete file paths, symbols, risk rankings, and open questions. Do not reduce a prior report to generic prose.

### Agent 1: Architect

Read `agents/architect.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Sonnet |
| Type | Explore (read-only) |
| Input | The spec document (spec-driven) or user description + codebase context (inline) |
| Token budget | 5000 for CodeSift calls |

**Expected output:** Architecture Report containing component boundaries, data flow, interfaces, dependency graph, and a Mermaid diagram.

Wait for the Architect report before dispatching the next agent.

### Agent 2: Tech Lead

Read `agents/tech-lead.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Sonnet |
| Type | Explore (read-only) |
| Input | The planning input (spec or user description) AND the Architect's report |
| Token budget | 5000 for CodeSift calls |

**Expected output:** Technical Decisions Report containing pattern selections, library choices, trade-offs, and file structure.

Wait for the Tech Lead report before dispatching the next agent.

### Agent 3: QA Engineer

Read `agents/qa-engineer.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Sonnet |
| Type | Explore (read-only) |
| Input | The planning input (spec or user description), Architect's report, AND Tech Lead's report |
| Token budget | 5000 for CodeSift calls |

**Expected output:** Quality Assessment containing testability review, CQ pre-check, test strategy, and risk areas.

Wait for the QA Engineer report before proceeding to Team Lead synthesis.

### Step 4: Team Lead Synthesis (Main Agent)

You are the Team Lead. You do NOT dispatch a sub-agent for this step. Read `agents/team-lead.md` for the synthesis procedure, then execute it yourself.

Using all three agent reports plus the original spec, decompose the work into ordered TDD tasks. This is the core deliverable of the plan skill.

---

## Phase 2: Plan Document

Write the plan document to `docs/specs/YYYY-MM-DD-<topic>-plan.md` using today's date and a topic slug derived from the spec.

### Plan Document Structure

```markdown
# Implementation Plan: [Feature Name]

**Spec:** [path to spec document | "inline — no spec"]
**spec_id:** [spec_id from the spec's header | "none"]
**planning_mode:** [spec-driven | inline]
**source_of_truth:** [approved spec | inline brief | inline brief (unapproved spec is context only)]
**plan_revision:** 1
**status:** Draft | Reviewed | Approved
**Created:** [date]
**Tasks:** [count]
**Estimated complexity:** [standard/complex mix summary]

## Architecture Summary
[Condensed from Architect report — component list, key interfaces, dependency direction]

## Technical Decisions
[Condensed from Tech Lead report — chosen patterns, libraries, file structure]

## Quality Strategy
[Condensed from QA Engineer report — test approach, risk areas, CQ gates to watch]

## Coverage Matrix
[Deterministic authority -> task mapping]

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 / G1 | [spec AC, deliverable, goal, or constraint] | requirement / deliverable / constraint | Task 2, Task 5 | [context-only note if needed] |

## Review Trail
- Plan reviewer: revision 1 -> APPROVED | ISSUES FOUND ([short summary])
- Cross-model validation: executed -> clean | findings fixed | skipped ([script reason])
- Status gate: Draft | Reviewed | Approved

## Task Breakdown

### Task 1: [Short descriptive name]
**Files:** [list of files to create or modify, with full paths]
**Complexity:** standard | complex
**Dependencies:** none | Task N, Task M
**Execution routing:** default implementation tier | deep implementation tier

- [ ] RED: [test goal — what behavior to assert, which file, which assertions]
- [ ] GREEN: [implementation targets — symbols to add/change, invariants, interfaces]
  [Optional: scaffold snippet ≤20 LOC if pattern is non-obvious]
- [ ] Verify: `[exact shell command]`
  Expected: [exact expected output or pattern]
- [ ] Acceptance: [which Coverage Matrix row(s) this task satisfies]
- [ ] Commit: `[commit message describing behavior added]`

### Task 2: [...]
...
```

### Task Authoring Rules

1. **Scope per task:** Each task should take 2-5 minutes to implement and represent one logical unit of work. If it would take longer, split it.
2. **Boundary size:** A task touching more than 5 files, more than one new public surface, or more than two system boundaries is oversized by default. Split it unless you can justify why the files are inseparable.
3. **Task intent over exact code:** RED steps include test intent, target assertions, and file path. GREEN steps include symbols to add/change, invariants to maintain, interfaces to implement, and reuse obligations. Include scaffold code only when the pattern is non-obvious, and keep scaffolds at or below 20 LOC. Do NOT write the full implementation.
4. **Exact verification:** The Verify step must include an exact shell command whose exit code proves the claimed invariant. If the expected output mentions a specific value or behavior, the command must assert that value or behavior rather than merely running a script.
5. **Acceptance mapping:** Every Coverage Matrix row must appear in at least one task's Acceptance field. No orphan requirements, deliverables, or constraints.
6. **Dependencies:** A task can only depend on tasks with a lower number. No circular dependencies. Dependencies must reflect real ordering, not preference.
7. **Complexity rating:** `standard` means 1-3 files, existing patterns, one system boundary, and no new public contract. `complex` means 4+ files, 2+ system boundaries, new patterns/contracts, cross-cutting concerns, or high-risk hotspot files. The complexity rating determines which implementation tier the execute phase will use: default for standard, deep for complex.
8. **File limits:** Use `../../rules/file-limits.md` as the planning default. In particular: utilities/helpers <=100 lines, controllers/services <=300 unless the rule explicitly allows more, components <=200/300, hooks <=250. If the plan would exceed these limits, split the task.
9. **Test files:** Every task that creates production code must include a test file. If a task is docs-only or config-only, say so explicitly in the RED step instead of implying a missing test.

---

## Phase 3: Plan Review

Dispatch the plan reviewer agent to verify the plan against the spec.

### Agent: Plan Reviewer

Read `agents/plan-reviewer.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Sonnet |
| Type | Explore (read-only) |
| Input | The planning input (spec or user description) AND the plan document |

**Expected output:** Review verdict — either APPROVED or ISSUES FOUND with specific items.

### Review Loop

1. If APPROVED on the current revision: append the verdict to `## Review Trail`, then proceed to cross-model validation.
2. If ISSUES FOUND: revise the plan to address the issues, increment `plan_revision`, update `## Review Trail`, then re-dispatch the reviewer on the new revision.
3. Maximum 3 review iterations. After 3, present the remaining issues to the user and let them decide whether to accept the plan as-is or provide guidance

### Cross-Model Validation (MANDATORY — do NOT skip)

After the plan-reviewer converges, run cross-model validation on the plan file. This catches task bloat, hidden ordering violations, and AC orphans.

```bash
adversarial-review --mode plan --files "docs/specs/YYYY-MM-DD-<topic>-plan.md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then apply fix policy:
- **CRITICAL** (missing dependency, task requires nonexistent file) → fix in plan, increment `plan_revision`, re-run plan-reviewer
- **WARNING** that changes task size, ordering, dependencies, verification, or coverage → fix in plan, increment `plan_revision`, re-run plan-reviewer
- **WARNING** that does NOT change execution semantics or coverage → append as note to the affected task and record it in `## Review Trail`
- **INFO** → ignore

Do not set `status: Reviewed` unless the current plan revision has:
1. a plan-reviewer `APPROVED` verdict,
2. a cross-model validation result or explicit script-generated skip reason, and
3. a populated `## Review Trail` reflecting both checks.

### User Approval

The plan follows a strict state machine:

```
Draft → Reviewed (reviewer converged + cross-model recorded) → Approved (by user only)
```

**Interactive mode:** Present the final plan. The user must explicitly approve. Update status to "Approved" only on user confirmation.

<!-- PLATFORM:CURSOR -->
**Async mode (Codex App, Cursor):** A converged reviewer verdict plus cross-model validation moves the plan to `Reviewed` status (NOT `Approved`). Print: "Plan is in Reviewed status. Review the task breakdown, then change status to Approved before running zuvo:execute."
<!-- /PLATFORM:CURSOR -->

`zuvo:execute` MUST check for "Approved" status. It will not start from "Draft" or "Reviewed".

---

## Active Plan Pointer

After the plan reaches `Approved` status, write the active plan pointer using the WRITE protocol from `session-state.md`:

```bash
mkdir -p .zuvo/plans
```

Write `.zuvo/plans/active-plan.md` with `status: pending`. If the plan is only `Reviewed`, do not write the pointer yet. This keeps `zuvo:execute` aligned with the same approval gate as the plan header.

---

## Output

The final plan document at `docs/specs/YYYY-MM-DD-<topic>-plan.md`.

This artifact is the prerequisite for `zuvo:execute`. When the user is ready to implement, the plan itself must be `Approved`; only then should `zuvo:execute` or the active-plan pointer treat it as the source of truth.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] All 3 Phase 1 agents ran sequentially (Architect → Tech Lead → QA Engineer)
[ ] Every spec AC maps to at least one task
[ ] Plan-reviewer ran and converged — APPROVED verdict
[ ] Adversarial validation ran (--mode plan)
[ ] Plan status is Approved (interactive) or Reviewed (async)
[ ] Active plan pointer written to .zuvo/plans/active-plan.md
[ ] Run: line printed and appended to log
```

```
Run: <ISO-8601-Z>	plan	<project>	-	-	<VERDICT>	<TASKS>	3-phase	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

---

## Progress Tracking

Report progress at each phase boundary:

```
STEP: Phase 1.1 — Architect Analysis [START]
... agent work ...
STEP: Phase 1.1 — Architect Analysis [DONE]
STEP: Phase 1.2 — Tech Lead Analysis [START]
... agent work ...
STEP: Phase 1.2 — Tech Lead Analysis [DONE]
STEP: Phase 1.3 — QA Engineer Analysis [START]
... agent work ...
STEP: Phase 1.3 — QA Engineer Analysis [DONE]
STEP: Phase 1.4 — Team Lead Synthesis [START]
... task decomposition ...
STEP: Phase 1.4 — Team Lead Synthesis [DONE]
STEP: Phase 2 — Plan Document [START]
... writing plan ...
STEP: Phase 2 — Plan Document [DONE]
STEP: Phase 3 — Plan Review [START]
... reviewer feedback + iterations ...
STEP: Phase 3 — Plan Review [DONE]
```

If `TaskCreate` is available (Claude Code), use structured task tracking instead of inline text.

---

## Failure Handling

- **Agent crash or timeout:** Retry once. If it fails again, log the error and perform that agent's analysis yourself using the CodeSift tools listed in the agent's instructions.
- **CodeSift unavailable:** Warn the user once ("CodeSift not available. Running in degraded mode."), then use Grep/Read/Glob fallbacks as described in `codesift-setup.md`.
- **Spec is ambiguous:** Do not guess. Ask the user to clarify the specific ambiguity before making planning decisions that depend on it.
- **Reviewer and plan disagree after 3 cycles:** Surface both positions to the user. Present the reviewer's concern and your rationale. Let the user decide.
