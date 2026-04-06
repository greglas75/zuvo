---
name: plan
description: "Activates when an approved spec exists and implementation has not started. Analyzes architecture, selects patterns, assesses testability, then decomposes the spec into ordered TDD tasks with exact code and verification commands."
---

# zuvo:plan

Create a detailed, task-by-task implementation plan from an approved spec document. Every task follows the TDD protocol: RED (failing test) -> GREEN (minimal code) -> Verify -> Commit.

---

## Hard Gate: Spec Document Required

Before doing anything else, locate the spec:

1. If the user provided an explicit path (e.g., `zuvo:plan docs/specs/my-spec.md`), use that file
2. Otherwise, search: `Glob("docs/specs/*-spec.md")`
3. If multiple specs exist, present the list and ask the user which one to plan against
4. If no spec is found:
   - Set status to `BLOCKED_MISSING_SPEC`
   - Print: "No spec document found in `docs/specs/`. A spec is required before planning."
   - Print: "Next action: run `zuvo:brainstorm` to create one."
   - Stop. Return `{ status: "BLOCKED_MISSING_SPEC", next: "zuvo:brainstorm" }`. Do not auto-invoke brainstorm.

Once a spec is found, read it in full. This is the source of truth for all planning decisions.

Verify the spec status:
- If `status: Approved` is NOT set in the spec header, stop with `BLOCKED_SPEC_NOT_APPROVED`.
- Print: "Spec is not approved. Review and set status to Approved before planning."
Return `{ status: "BLOCKED_SPEC_NOT_APPROVED", next: "approve spec" }`.

---

## Artifact Detection

Check if a plan already exists for this spec:

1. `Glob("docs/specs/*-plan.md")` — look for existing plans
2. If a matching plan exists, determine the match by reading the plan's `**spec_id:**` field and comparing it to the spec's `spec_id`. Matching is ONLY by `spec_id`, never by filename or path.
3. If no plan exists, proceed to Phase 1

---

## Mandatory File Loading

Before starting work, read each file below using the Read tool. Print the checklist with status. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md  -- READ/MISSING
  2. ../../shared/includes/env-compat.md       -- READ/MISSING
  3. ../../shared/includes/quality-gates.md    -- READ/MISSING
  4. ../../shared/includes/tdd-protocol.md     -- READ/MISSING
  5. ../../shared/includes/run-logger.md       -- READ/MISSING
```


**If 1-2 files missing:** Proceed in degraded mode. Note which files are unavailable in the final output.
**If 3+ files missing:** Stop. The plugin installation is incomplete.

Execute the CodeSift setup procedure from `codesift-setup.md`. Note the repo identifier for agent dispatches when CodeSift is available.

---

## Phase 1: Architecture Analysis

Dispatch 3 agents SEQUENTIALLY. Each agent receives the output of the previous agent(s) as input context. The 4th step is performed by you (the main agent) as Team Lead synthesis.

The sequential order is mandatory because each agent's analysis depends on what came before: the Architect maps the terrain, the Tech Lead makes decisions based on that map, and the QA Engineer assesses testability of those decisions.

### Agent 1: Architect

Read `agents/architect.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Sonnet |
| Type | Explore (read-only) |
| Input | The full spec document |
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
| Input | The spec document AND the Architect's report |
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
| Input | The spec document, Architect's report, AND Tech Lead's report |
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

**Spec:** [path to spec document]
**spec_id:** [spec_id from the spec's header]
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
- [ ] Acceptance: [which spec AC this task satisfies]
- [ ] Commit: `[commit message describing behavior added]`

### Task 2: [...]
...
```

### Task Authoring Rules

1. **Scope per task:** Each task should take 2-5 minutes to implement. If a task would take longer, split it.
2. **Task intent over exact code:** RED steps include: test intent, target assertions, and file path. GREEN steps include: symbols to add/change, invariants to maintain, and interfaces to implement. Include scaffold code or snippets (≤20 lines) when the pattern is non-obvious. Do NOT write the full implementation — that is the implementer's job. The plan specifies WHAT and WHY, the implementer decides HOW.
3. **Exact verification:** The Verify step includes the shell command to run and what the output should look like. No vague "tests should pass" — specify the command and expected result.
4. **Commit messages:** Describe the behavior added ("add order validation that rejects negative quantities"), not the files changed ("update order.service.ts").
5. **Dependencies:** A task can only depend on tasks with a lower number. No circular dependencies. Minimize dependencies — prefer independent tasks that can run in any order.
6. **Complexity rating:** `standard` means 1-3 files, clear spec, no architecture decisions. `complex` means 4+ files, design pattern selection, or cross-cutting concerns. The complexity rating determines which implementation tier the execute phase will use: default for standard, deep for complex.
7. **File limits:** No single file should exceed 300 lines (services) or 200 lines (components). If the plan would create a file larger than this, split the task.
8. **Test files:** Every task that creates production code must include a test file. The test file appears in the Files list alongside the production file.

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
| Input | The spec document AND the plan document |

**Expected output:** Review verdict — either APPROVED or ISSUES FOUND with specific items.

### Review Loop

1. If APPROVED: proceed to user review
2. If ISSUES FOUND: revise the plan to address the issues, then re-dispatch the reviewer
3. Maximum 3 review iterations. After 3, present the remaining issues to the user and let them decide whether to accept the plan as-is or provide guidance

### User Approval

The plan follows a strict state machine:

```
Draft → Reviewed (by plan reviewer) → Approved (by user only)
```

**Interactive mode:** Present the final plan. The user must explicitly approve. Update status to "Approved" only on user confirmation.

**Async mode (Codex App, Cursor):** The plan reviewer's APPROVED verdict moves the plan to "Reviewed" status (NOT "Approved"). Print: "Plan is in Reviewed status. Review the task breakdown and change status to Approved before running zuvo:execute."

`zuvo:execute` MUST check for "Approved" status. It will not start from "Draft" or "Reviewed".

---

## Output

The approved plan document at `docs/specs/YYYY-MM-DD-<topic>-plan.md`.

This artifact is the prerequisite for `zuvo:execute`. When the user is ready to implement, they invoke `zuvo:execute` and it picks up this plan automatically.

```
Run: <ISO-8601-Z>	plan	<project>	-	-	<VERDICT>	<TASKS>	3-phase	<NOTES>	<BRANCH>	<SHA7>
```

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
