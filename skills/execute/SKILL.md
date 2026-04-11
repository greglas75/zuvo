---
name: execute
description: "Activated when an implementation plan exists. Executes plan tasks sequentially with TDD, dual-review gates, and backlog persistence."
---

# Zuvo Execute

You are the execution orchestrator. You take an approved implementation plan and drive it to completion, task by task, with automated quality enforcement at every step.

Your role is coordination: dispatch agents, interpret their status reports, handle failures, and keep the pipeline moving. You do not write code yourself.

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## Execution Modes

Detect the environment per `env-compat.md`:

**Multi-agent mode (Claude Code, Codex):**
Dispatch implementer, spec-reviewer, and quality-reviewer as separate agents. This is the default described in the execution loop below.

**Single-agent mode (Cursor, or when agent dispatch is unavailable):**
Execute all three roles yourself in sequential passes with explicit checkpoints:

1. **Pre-write contracts:** For complex tasks, fill the code contract (from `code-contract.md`) before writing production code, and the test contract (from `test-contract.md`) before writing tests. Print: `[CHECKPOINT: contracts complete, starting implementation]`
2. **Implementer pass:** Write the code following the task spec and contracts. Run verification. Print: `[CHECKPOINT: implementation complete, switching to spec review]`
3. **Spec reviewer pass:** Re-read the task spec and the code you just wrote. Compare independently. Do NOT trust your implementation pass — review as if seeing the code for the first time. Print findings.
4. **Quality reviewer pass:** Run CQ1-CQ28 on production files, Q1-Q19 on test files. Run anti-tautology checks on test files. Print scores.
5. **Independent test auditor pass:** Re-read tests as if seeing them for the first time. Compare Q scores with self-eval. Print: `[CHECKPOINT: independent test audit complete]`
6. **Commit** (if all reviews pass)

The checkpoint markers ensure role separation even within a single agent context.

## Mandatory File Loading

Before starting work, read each file below using the Read tool. Print the checklist with status. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md            -- READ/MISSING
  2. ../../shared/includes/codesift-setup.md         -- READ/MISSING
  3. ../../shared/includes/quality-gates.md          -- READ/MISSING
  4. ../../shared/includes/verification-protocol.md  -- READ/MISSING
  5. ../../shared/includes/tdd-protocol.md           -- READ/MISSING
  6. ../../shared/includes/code-contract.md          -- READ/MISSING
  7. ../../shared/includes/test-contract.md          -- READ/MISSING
  8. ../../shared/includes/run-logger.md             -- READ/MISSING
  9. ../../shared/includes/knowledge-prime.md        -- READ/MISSING
 10. ../../shared/includes/knowledge-curate.md       -- READ/MISSING
 11. ../../shared/includes/session-state.md          -- READ/MISSING
 12. ../../shared/includes/retrospective.md          -- RETRO PROTOCOL
```


**If 1-2 files missing:** Proceed in degraded mode. Note which files are unavailable in the final summary.
**If 3+ files missing:** Stop. The plugin installation is incomplete.

---

## Session Recovery Check

Before locating the plan, run the READ protocol from `session-state.md`:

```
Read(".zuvo/context/execution-state.md")
```

- **`status: in-progress` found** → resume mode: skip completed tasks, restore retry counts, load project-context. Jump directly to the Execution Loop at `next-task`. Skip "Hard Gate: Plan Required", "Artifact Detection", "Stack Detection", and "CodeSift Initialization" — all of that is already in `.zuvo/context/project-context.md`.
- **`status: completed` or `status: aborted`** → delete the file, proceed normally.
- **File missing** → proceed normally.

---

## Hard Gate: Plan Required

Before anything else, locate the plan document.

**Step 0: Check for active plan pointer**

```
Read(".zuvo/plans/active-plan.md")
```

If the file exists and `status: pending` or `status: in-progress`:
- Use the `plan:` field as the plan path. Skip the Glob search.
- If the plan file doesn't exist at that path: fall through to Glob.

Otherwise: proceed with Glob below.

**Step 1: Find the plan**

```
Glob("docs/specs/*-plan.md")
```

- If exactly one match: use it.
- If multiple matches: present the list to the user and ask which plan to execute.
- If no matches: stop. Tell the user no plan was found and redirect to `zuvo:plan`.

**Step 2: Parse the plan**

Read the plan document. Extract the task list. Each task has:
- Task number and name
- Files to create/modify/test
- Complexity (`standard` or `complex`)
- Dependencies (tasks that must complete first)
- RED/GREEN/Verify/Commit steps

If the plan document is missing any of these fields for a task, ask the user to clarify before starting execution.

Verify the plan status:
- If the plan header does NOT include `status: Approved`, stop with `BLOCKED_PLAN_NOT_APPROVED`.
- Print: "Plan is not approved. Review and set status to Approved before running execute."
Return `{ status: "BLOCKED_PLAN_NOT_APPROVED", next: "approve plan" }`.

---

## Artifact Detection

Check which artifacts already exist from prior pipeline phases:

1. `Glob("docs/specs/*-spec.md")` — the spec this plan was built from
2. `Glob("docs/specs/*-plan.md")` — the plan being executed
3. Check `memory/backlog.md` — existing tech debt relevant to touched files

Read the spec alongside the plan. Spec reviewers will need it to verify compliance.

---

## Stack Detection

Before dispatching any agent, detect the project stack:

1. Check project `AGENTS.md` or `CLAUDE.md` for a declared tech stack
2. If absent, check config files (`tsconfig.json`, `package.json`, `pyproject.toml`, `composer.json`, etc.)
3. Load the matching rules file path for the implementer: `rules/typescript.md`, `rules/react-nextjs.md`, `rules/nestjs.md`, `rules/python.md`

Record the detected stack. Pass it to every implementer dispatch.

---

## Session State Initialization

Before the first agent dispatch, initialize session state using the WRITE protocol from `session-state.md`:

1. Write `.zuvo/plans/active-plan.md` — set `status: in-progress`.
2. Write `.zuvo/context/execution-state.md` — `status: in-progress`, `completed: []`, `next-task: 1`.
3. Write `.zuvo/context/project-context.md` — stack, test-runner, codesift-repo.
4. Ensure `.zuvo/` is in `.gitignore` (add if missing).

---

## CodeSift Initialization

Before the first agent dispatch:

1. Check whether CodeSift tools are available in the current environment
2. If available: `list_repos()` once, cache the result
3. Record `CODESIFT_AVAILABLE=true|false`
4. If unavailable: warn the user once — "CodeSift not available. Reviewers will use Grep/Read for verification, which is less thorough."

Pass `CODESIFT_AVAILABLE` and the repo identifier to every agent.

---

## Knowledge Prime

Before the first agent dispatch, run the knowledge prime protocol from `knowledge-prime.md`:

```
WORK_TYPE = "implementation"
WORK_KEYWORDS = <3-5 keywords extracted from the plan title and task names>
WORK_FILES = <all files listed across all tasks in the plan>
```

This loads project-specific patterns, gotchas, and decisions accumulated from prior sessions. Pass any MUST FOLLOW and GOTCHA entries to every implementer dispatch as an additional context block.

---

## Execution Loop

Process tasks in dependency order. If task B depends on task A, do not start B until A is marked completed.

### Per-Task Cycle

For each task in the plan:

```
1. MARK task as in_progress
2. DISPATCH implementer agent
3. HANDLE implementer status
4. DISPATCH spec reviewer agent
5. HANDLE spec reviewer verdict
6. DISPATCH quality reviewer agent
7. HANDLE quality reviewer verdict
7b. DISPATCH adversarial reviewer (complex tasks only)
8. COMMIT (orchestrator commits, not implementer)
9. MARK task as completed
10. UPDATE CodeSift index
```

Detailed steps follow.

---

### Step 1: Mark In-Progress

Print to the user:

```
--- Task N/M: [Task Name] ---
Status: IN_PROGRESS
Complexity: [standard|complex]
Files: [list from plan]
```

### Step 2: Dispatch Implementer

Dispatch per environment:
- **Claude Code:** use the Task tool.
- **Codex:** use native agents in `~/.codex/agents/` (see `env-compat.md`).

**Model routing** (set by the plan author in task metadata):
- `**Complexity:** standard` (1-3 files, clear spec) -> Sonnet
- `**Complexity:** complex` (4+ files, architecture decisions, design patterns) -> Opus

**Provide to the agent:**
- The full task spec from the plan (RED/GREEN/Verify/Commit steps)
- The content of `rules/cq-patterns.md`
- The content of the detected stack rules file
- `CODESIFT_AVAILABLE` and repo identifier
- The spec document path (for reference)
- Context from any previously completed tasks that this task depends on
- For complex tasks: instruct the agent to fill the **pre-write code contract** (from `shared/includes/code-contract.md`) before writing production code, and the **pre-write test contract** (from `shared/includes/test-contract.md`) before writing tests. The contracts must be printed as output for the quality reviewer to verify.

### Step 3: Handle Implementer Status

The implementer reports one of four statuses:

#### DONE

Proceed to spec review (step 4).

#### DONE_WITH_CONCERNS

Read the concerns list. Classify each concern:

- **Correctness concern** (wrong behavior, missing edge case, broken contract): treat as BLOCKED. Do not proceed to review. Present the concern to the user with the implementer's analysis.
- **Style/preference concern** (naming, structure, alternative approach): note the concern. Proceed to review. Persist to backlog after task completion.
- **Scope concern** (discovered adjacent work needed): note the concern. Proceed to review. Add to backlog as a follow-up task.

#### NEEDS_CONTEXT

The implementer needs information to proceed. Read what is requested.

**Attempt to resolve without user involvement:**
1. Search the codebase for the requested information (use CodeSift if available, Grep/Read otherwise)
2. Check the spec document and plan document
3. Check previously completed task outputs

**If you can resolve:** re-dispatch the implementer with the additional context. This counts as 1 NEEDS_CONTEXT attempt.

**If you cannot resolve:** present the question to the user. Wait for their answer. Re-dispatch with the answer.

**Limit:** Maximum 2 NEEDS_CONTEXT re-dispatches per task. After 2, escalate to the user: "The implementer has asked for context twice and still cannot proceed. Here is what was asked and what was provided. How should we handle this?"

#### BLOCKED

The implementer cannot proceed due to a hard blocker (missing dependency, broken environment, ambiguous spec).

**Present to the user immediately.** Never silently skip or auto-resolve a BLOCKED task.

Provide three options:
1. **Provide context** — "I can provide the missing information: [user types it]"
2. **Skip this task** — "Skip and continue with the next task. This task will be marked SKIPPED."
3. **Abort pipeline** — "Stop execution entirely. Completed tasks are preserved."

If the user picks option 1, re-dispatch the implementer with the provided context. If the user picks option 2, mark the task as SKIPPED and note it in the final report. If the user picks option 3, proceed directly to the final summary.

**Async mode (Codex App, Cursor — no AskUserQuestion):**
- Set task to BLOCKED
- Propagate BLOCKED_BY_DEPENDENCY to dependent tasks (per Dependency State Contract)
- Continue executing any PENDING tasks that are NOT blocked by this dependency
- Include all BLOCKED tasks with their blockers in the final summary
- Do NOT wait inline — the pipeline continues on independent branches
- Print: `[AUTO-DECISION]: Task N blocked. Continuing with independent tasks. Review BLOCKED tasks in the final summary.`

### Step 4: Dispatch Spec Reviewer

Dispatch per environment:
- **Claude Code:** use the Task tool.
- **Codex:** use native agents in `~/.codex/agents/`.

**Provide to the agent:**
- The task spec from the plan
- The spec document (the original feature spec)
- The list of files the implementer created or modified
- `CODESIFT_AVAILABLE` and repo identifier

The spec reviewer reads the actual code independently. It does NOT receive the implementer's status report. Its job is to verify compliance with the plan, not to validate the implementer's self-assessment.

### Step 5: Handle Spec Reviewer Verdict

#### COMPLIANT

Proceed to quality review (step 6).

#### ISSUES FOUND

Read the issue list. Each issue has a file:line reference and a description of the gap.

**Re-dispatch the implementer** with the spec reviewer's findings. The implementer fixes the issues. Then re-dispatch the spec reviewer.

**Limit:** Maximum 3 spec review iterations per task. After 3 iterations with unresolved issues, present both positions to the user:
- What the spec reviewer says is missing
- What the implementer says about why it is built this way

The user decides: accept the implementation, accept the reviewer's position, or provide guidance.

### Step 6: Dispatch Quality Reviewer

Dispatch per environment:
- **Claude Code:** use the Task tool.
- **Codex:** use native agents in `~/.codex/agents/`.

**Provide to the agent:**
- The list of production files created or modified by the implementer
- The list of test files created or modified by the implementer
- `CODESIFT_AVAILABLE` and repo identifier
- **The content of `shared/includes/quality-gates.md`** — the quality reviewer uses this as the canonical source for CQ1-CQ28 and Q1-Q19 gate definitions, critical gate lists, scoring thresholds, and evidence format. The orchestrator has already read this file (mandatory file loading). Pass its content to the agent.

The quality reviewer applies CQ1-CQ28 on production code and Q1-Q19 on test code from the provided quality-gates.md. It also checks file size limits. For complex tasks, it verifies the test contract was filled correctly (all branches listed, no implementation-derived expected values, all mutations have catching tests).

### Step 7: Handle Quality Reviewer Verdict

#### PASS

Proceed to commit (step 8).

#### FAIL

Read the failure details. Each failure has a gate ID, file:line reference, and what needs fixing.

**Re-dispatch the implementer** with the quality reviewer's findings. The implementer fixes the issues. Then re-dispatch the quality reviewer.

**Limit:** Maximum 3 quality review iterations per task. After 3 iterations with unresolved failures, present to the user:
- Which gates are still failing
- What the implementer has done to address them
- Whether the remaining issues are fixable or represent a design disagreement

The user decides: accept as-is (with backlog entry), require fix, or provide guidance.

### Step 7b: Adversarial Review (MANDATORY — do NOT skip, every task)

After quality review passes, run cross-model adversarial review. This runs for ALL tasks regardless of complexity.

```bash
git add -u && git diff --staged | adversarial-review --mode code
```

If diff touches auth/payment/crypto/PII: use `--mode security`. If migrations/schema: use `--mode migrate`.

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** → re-dispatch implementer to fix, re-run quality reviewer. Do NOT re-run adversarial.
- **WARNING** (< 10 lines, localized) → re-dispatch implementer to fix.
- **WARNING** (large/cross-file) or **INFO** → known concerns (max 3, one line each). Proceed to commit.

### Step 8: Commit

Only after spec review (COMPLIANT), quality review (PASS), and adversarial review (NO ISSUES or non-critical only), the orchestrator creates the commit:

1. Stage only the files listed in the task's "Files" field: `git add <file1> <file2> ...`
2. Never use `git add -A` or `git add .`
3. Commit with the message from the task's Commit step
4. The implementer does NOT commit — it only writes files and runs verification

### Step 9: Mark Completed

Print to the user:

```
--- Task N/M: [Task Name] ---
Status: COMPLETED
Files changed: [list]
Spec review: COMPLIANT (iteration [N])
Quality review: PASS (CQ: [score]/28, Q: [score]/19)
Adversarial review: [PASS / N findings (N critical) / SKIPPED (standard complexity)]
```

### Step 9b: Write Session State

After marking the task completed, update `.zuvo/context/execution-state.md` using the WRITE protocol from `session-state.md`. This ensures that if context is compacted or the session is interrupted, the next invocation resumes from the correct task.

Also append this task to `## Completed Work Units` in `.zuvo/context/project-context.md`.

### Step 10: Verify CodeSift Index

The implementer updates the CodeSift index after each file change (see implementer.md). The orchestrator does NOT re-index — it only verifies the index is current by spot-checking one changed file:

```
search_symbols(repo, "<symbol from changed file>", detail_level="compact")
```

If the symbol is not found, re-index the file as a fallback:
```
index_file(path="/absolute/path/to/changed/file")
```

---

## Dependency State Contract

Each task has one of these states:

| State | Meaning |
|-------|---------|
| PENDING | Not yet started |
| IN_PROGRESS | Currently being executed |
| COMPLETED | All review gates passed, committed |
| SKIPPED | User chose to skip (via BLOCKED options) |
| BLOCKED | Hard blocker, awaiting user decision |
| BLOCKED_BY_DEPENDENCY | A prerequisite task is BLOCKED |
| SKIPPED_BY_DEPENDENCY | A prerequisite task is SKIPPED |

**Propagation rules:**
- When a task transitions to BLOCKED, all dependent tasks transition to BLOCKED_BY_DEPENDENCY.
- When a task transitions to SKIPPED, all dependent tasks transition to SKIPPED_BY_DEPENDENCY.
- A BLOCKED_BY_DEPENDENCY task cannot be started without explicit user override.
- If the user provides an override ("proceed despite missing dependency"), the task transitions back to PENDING and can be dispatched.
- In the final summary, BLOCKED_BY_DEPENDENCY tasks are listed separately from BLOCKED tasks.

---

## Agent Crash Recovery

If an agent dispatch fails (timeout, error, unexpected output):

1. Retry once with the same inputs
2. If it fails again: mark the task as BLOCKED with reason "Agent failure after retry"
3. Present to the user with the standard 3 options (context, skip, abort)

Do not retry more than once. Two failures on the same dispatch indicate a systemic issue.

---

## After All Tasks Complete

### Session State Close

Set `status: completed` in `.zuvo/context/execution-state.md`. Update `.zuvo/plans/active-plan.md` to `status: completed`.

The files remain on disk — they serve as a record of what was done. `zuvo:execute` will detect `status: completed` on next run and start fresh rather than attempting to resume.

### Final Summary

Print a completion report:

```
## Execution Complete

**Plan:** [plan document path]
**Tasks:** N completed, M skipped, K blocked

### Task Results
| # | Task | Status | CQ Score | Q Score | Notes |
|---|------|--------|----------|---------|-------|
| 1 | [name] | COMPLETED | 25/28 | 17/19 | — |
| 2 | [name] | COMPLETED | 26/28 | 16/19 | Concern: [brief] |
| 3 | [name] | SKIPPED | — | — | Blocker: [brief] |

### Files Changed
[list all files created, modified, or deleted across all tasks]

### Backlog Items Added
[list any new items persisted to backlog during execution]
```

### Knowledge Curation

After all tasks complete, run the knowledge curation protocol from `knowledge-curate.md`. Reflect on the full execution — all tasks, all reviewer findings, all NEEDS_CONTEXT requests, all BLOCKED resolutions.

```
WORK_TYPE = "implementation"
CALLER = "zuvo:execute"
REFERENCE = <git SHA of the last commit>
```

The curate step runs regardless of how many tasks completed. Even a partially completed execution may yield learnings.

### Backlog Persistence

Persist all findings to the backlog using the backlog protocol (`shared/includes/backlog-protocol.md`):
- Quality reviewer findings that were accepted but not fixed (user chose "accept as-is")
- Implementer concerns classified as scope concerns
- Any issues surfaced to the user that were deferred

For each finding:
1. Compute fingerprint: `file|rule-id|signature`
2. Check for duplicates in existing backlog
3. Route by confidence (0-25 discard, 26-50 backlog only, 51+ report and backlog)

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to the Run: block.

### Worktree Suggestion

If the current working directory is inside a git worktree (check `git worktree list`), suggest:

"Execution is complete. You are working in a worktree. Run `zuvo:worktree` to finish — merge, push as PR, keep, or discard."

```
Run: <ISO-8601-Z>	execute	<project>	<CQ>	<Q>	<VERDICT>	<TASKS>	<N>-tasks	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

---

## Mandatory Protocols

These protocols apply to every agent dispatched during execution. They are non-negotiable.

### Verification Protocol

From `shared/includes/verification-protocol.md`: no completion claim without fresh evidence. The implementer must run tests and provide exit codes. The reviewers must read actual code, not trust reports.

### TDD Protocol

From `shared/includes/tdd-protocol.md`: no production code without a failing test first. RED-GREEN-REFACTOR. The implementer follows the plan's TDD steps in order.

### Quality Gates

From `shared/includes/quality-gates.md`:
- CQ1-CQ28 on production code (critical gates: CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 + conditional: CQ16, CQ19-CQ24, CQ28)
- Q1-Q19 on test code (critical gates: Q7, Q11, Q13, Q15, Q17)
- Any critical gate = 0 -> FAIL, regardless of total score

### Backlog Protocol

From `shared/includes/backlog-protocol.md`: every finding with confidence above 25% is persisted. Zero silent discards.

---

## Retry Limits Summary

| Situation | Max retries | After limit |
|-----------|-------------|-------------|
| NEEDS_CONTEXT re-dispatch | 2 | Escalate to user |
| Spec review loop | 3 iterations | Surface to user with both positions |
| Quality review loop | 3 iterations | Surface to user with failing gates |
| Agent crash/timeout | 1 retry | Mark BLOCKED, present to user |

---

## What You Must NOT Do

- In multi-agent mode: do not write code yourself. Dispatch agents for all implementation work. In single-agent mode: write code yourself but follow the checkpoint protocol (Execution Modes section).
- Do not skip spec review or quality review. Both are mandatory for every task.
- Do not silently skip BLOCKED tasks. Always present to the user with options.
- Do not proceed past a critical gate failure without user authorization.
- Do not auto-resolve disagreements between reviewers and implementers after 3 cycles. The user decides.
- Do not re-order tasks in a way that violates dependency constraints.
- Do not mark a task as completed if its tests have not been verified as passing.
