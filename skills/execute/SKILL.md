---
name: execute
description: "Activated when an implementation plan exists. Executes plan tasks sequentially with enforced review gates, adversarial validation, and resumable session state."
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols
    - get_symbol
    - get_symbols
    - get_file_outline
    - find_references          # task-step impact check
    - search_text
    - search_patterns          # follow conventions during code edits
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_middleware, astro_sessions, astro_image_audit, astro_svg_components]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders]
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

# Zuvo Execute

You are the execution orchestrator. You take an approved implementation plan and drive it to completion, task by task, with automated quality enforcement at every step.

Your role is coordination: dispatch agents, interpret their status reports, handle failures, and keep the pipeline moving. You do not write code yourself.

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## Execution Modes

Detect the environment per `env-compat.md`:

**Multi-agent mode (Claude Code, Codex when dispatch is actually available):**
Dispatch implementer, spec-reviewer, and quality-reviewer as separate agents. This is the preferred mode described in the execution loop below.

**Fallback rule (MANDATORY):**
If agent dispatch is unavailable, disallowed by the current runtime, or fails twice for the same stage:
- Print: `[MODE SWITCH] Falling back to single-agent. All checkpoints remain mandatory.`
- Record the fallback reason in task telemetry and the final summary (`dispatch-unavailable`, `dispatch-disallowed`, `agent-failure`, or `same-model-fallback`).
- Continue only with the single-agent checkpoint protocol below. Never silently drop spec review, quality review, adversarial review, or session-state updates.

**Single-agent mode (Cursor, or any runtime where multi-agent dispatch is unavailable):**
Execute all roles yourself in sequential passes with explicit checkpoints:

1. **Pre-write contracts:** For complex tasks, fill the code contract (from `code-contract.md`) before writing production code, and the test contract (from `test-contract.md`) before writing tests. Print: `[CHECKPOINT: contracts complete, starting implementation]`
2. **Implementer pass:** Write the code following the task spec and contracts. Run verification. Print: `[CHECKPOINT: implementation complete, switching to spec review]`
3. **Spec reviewer pass:** Re-read the task spec and the code you just wrote. Compare independently. Do NOT trust your implementation pass — review as if seeing the code for the first time. Print findings and: `[GATE: spec-compliance] <3 plan requirements satisfied, or BLOCKED with exact gap>`
4. **Quality reviewer pass:** Run CQ1-CQ29 on production files, Q1-Q19 on test files. Run anti-tautology checks on test files. **Report per-file scores — aggregate scoring is forbidden.** Print scores and: `[GATE: cq-critical] <critical gates checked + evidence>`
5. **Independent test auditor pass:** Re-read tests as if seeing them for the first time. Compare Q scores with self-eval. Print: `[CHECKPOINT: independent test audit complete]`
6. **Adversarial pass:** Run the same adversarial review required in Step 7b. Print: `[GATE: adversarial-done] PASS|WARNING|CRITICAL|BLOCKED <mode + artifact path or exact blocker>`
7. **Acceptance verifier pass (MANDATORY):** Read the task's Acceptance Proof block from the plan. Set up preconditions, run the proof, capture artifact to `.zuvo/proofs/task-<N>-<ac-id>.<ext>`. Behavior must match Expected. Print: `[CHECKPOINT: switching to acceptance-verifier role]` then `[GATE: acceptance-verified] <ac-ids passed | BLOCKED with failing AC# + observed-vs-expected>`
8. **Commit** (only if all reviews and acceptance gates pass)
9. **Session durability pass:** Rewrite `execution-state.md` immediately after the commit. Print: `[GATE: state-written] <task N, sha7, next-task>`

The checkpoint markers and gate markers ensure role separation even within a single agent context. Missing any `[GATE: ...]` marker — including `[GATE: acceptance-verified]` — is a contract violation and the task remains IN_PROGRESS.

## Mandatory File Loading

### Phase 0 — Bootstrap (load before any work)

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md                  -- READ/MISSING
  2. ../../shared/includes/codesift-setup.md              -- OPTIONAL/READ IF AVAILABLE
  3. ../../shared/includes/quality-gates.md               -- READ/MISSING
  4. ../../shared/includes/verification-protocol.md       -- READ/MISSING
  5. ../../shared/includes/tdd-protocol.md                -- READ/MISSING
  6. ../../shared/includes/session-state.md               -- READ/MISSING
  7. ../../shared/includes/no-pause-protocol.md           -- READ/MISSING (HARD: no mid-loop pauses)
  8. ../../shared/includes/acceptance-proof-protocol.md   -- READ/MISSING (HARD: per-task + smoke proof gates)
  9. ../../shared/includes/code-contract.md               -- DEFERRED (task dispatch)
 10. ../../shared/includes/test-contract.md               -- DEFERRED (task dispatch)
 11. ../../shared/includes/knowledge-prime.md             -- DEFERRED (task dispatch)
 12. ../../shared/includes/knowledge-curate.md            -- DEFERRED (completion)
 13. ../../shared/includes/run-logger.md                  -- DEFERRED (completion)
 14. ../../shared/includes/retrospective.md               -- DEFERRED (completion)
```


**If 1-2 files missing:** Proceed in degraded mode. Note which files are unavailable in the final summary.
**If 3+ files missing:** Stop. The plugin installation is incomplete.

---

## Session Recovery Check

Before locating the plan, run the READ protocol from `session-state.md`:

```
Read(".zuvo/context/execution-state.md")
```

- **`status: in-progress` found** → resume mode: skip completed tasks, restore retry counts, load project-context. Jump directly to the Execution Loop at `next-task`. Skip "Hard Gate: Plan Required", "Artifact Detection", "Stack Detection", and "CodeSift Integration" — all of that is already in `.zuvo/context/project-context.md`.
- **`status: completed` or `status: aborted`** → follow the rename/archive behavior from `session-state.md`, then proceed normally.
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
2. Write `.zuvo/context/execution-state.md` — `status: in-progress`, `completed: []`, `next-task: <lowest task number from the plan>`.
3. Write `.zuvo/context/project-context.md` — stack, test-runner, codesift-repo.
4. Ensure `.zuvo/` is in `.gitignore` (add if missing).

---

## CodeSift Integration

CodeSift is optional during execute. Execute uses Read/Grep/Bash as the default file-operation path and does NOT depend on a startup repo scan.

Before the first agent dispatch:

1. Detect whether CodeSift tools are available in the current environment
2. Record `CODESIFT_AVAILABLE=true|false`
3. If available: pass the repo identifier when you already have it, otherwise let CodeSift auto-resolve from CWD
4. If unavailable: do not warn repeatedly. Note it once in telemetry and continue

Use CodeSift only when it adds concrete value during execute:
- resolving `NEEDS_CONTEXT` requests (`search_text`, `find_references`, `trace_call_chain`)
- blast-radius checks after constructor/signature changes
- `index_file(path)` after each edited file when available

Do NOT require `list_repos()` or a `search_symbols()` spot-check before the task can finish.

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

## Required Telemetry

For every task, emit a compact telemetry block after verification and include mode shifts again in the final summary.

Minimum fields:
- `task`: number and name
- `surface`: from plan task header (backend-logic / api / db / db-data / ui / integration / config / docs)
- `mode`: `multi-agent` or `single-agent`
- `fallback-path`: `none`, `dispatch-unavailable`, `dispatch-disallowed`, `agent-failure`, or `same-model-fallback`
- `writer-model`: actual implementer model/lane used for the task
- `reviewer-route`: `review-primary`, `review-alt`, `same-model-fallback`, or `routing-failed`
- `implementer-status`: `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`
- `spec-review`: `COMPLIANT` or `ISSUES FOUND`
- `quality-review`: `PASS` or `FAIL` — **with per-file scores; aggregate forbidden** (e.g. `cq=27/29@codec.ts,28/29@parser.ts; q=18/19@codec.test.ts,17/19@parser.test.ts` not `cq=27/29 q=18/19 aggregate`)
- `adversarial`: verdict plus mode (`code`, `security`, `migrate`)
- `verify`: command(s) and exit code(s) — implementation-detail check
- `acceptance-verified`: list of AC ids passed plus artifact paths (e.g. `AC1@.zuvo/proofs/task-4-AC1.txt,AC3@.zuvo/proofs/task-4-AC3.txt`) — behavior check
- `codesift`: `available`, `unavailable`, or `index-failed`
- `backlog-adds`: integer count for this task

**Per-file scoring is mandatory.** A telemetry block reporting `q_gates: 19/19 aggregate` is rejected by the completion gate. Aggregate averaging hides per-file zeros — the documented proximate cause of the 2026-04-22 codec session shipping with Q7=0 and Q11=0 in specific files while telemetry reported all-green.

Example:

```text
[TELEMETRY]
task=4 "Tenant extension hardening"
surface=api
mode=single-agent
fallback-path=agent-failure
writer-model=sonnet
reviewer-route=same-model-fallback
implementer-status=DONE
spec-review=COMPLIANT
quality-review=PASS cq=27/29@tenant.ts,28/29@guards.ts q=18/19@tenant.test.ts
adversarial=PASS mode=security
verify="pnpm vitest run src/foo.spec.ts" exit=0
acceptance-verified=AC2@.zuvo/proofs/task-4-AC2.txt,AC5@.zuvo/proofs/task-4-AC5.txt
codesift=available
backlog-adds=1
```

---

## Execution Loop

Process tasks in dependency order. If task B depends on task A, do not start B until A is marked completed.

**HARD CONTINUATION RULE (per `no-pause-protocol.md`):** After Step 9b (telemetry) of task N, IMMEDIATELY start task N+1. Do NOT estimate remaining wall-clock time, do NOT extrapolate session capacity, do NOT present A/B/C menus, do NOT ask "want me to continue?". The plan was approved at the entry gate — that approval covers ALL tasks. Only legitimate stops: BLOCKED_* states, all tasks terminal, explicit user "stop"/"pause"/"wystarczy", or `/context` >85% (write state and exit, do NOT ask).

### Per-Task Cycle

For each task in the plan:

```
1. MARK task as in_progress
2. DISPATCH implementer agent
3. HANDLE implementer status
4. DISPATCH spec reviewer agent (textual compliance with plan)
5. HANDLE spec reviewer verdict
6. DISPATCH quality reviewer agent (per-file CQ/Q scoring — no aggregate)
7. HANDLE quality reviewer verdict
7b. DISPATCH adversarial reviewer (every task)
7c. ENFORCE self-review gates and branch-drift check
7d. RUN ACCEPTANCE PROOF (behavior check — the gate the codec session was missing)
8. COMMIT (orchestrator commits, not implementer)
9. WRITE session state immediately
9b. MARK task as completed + emit telemetry (per-file scores + acceptance-verified)
10. UPDATE project context + optional CodeSift index
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
<!-- PLATFORM:CODEX -->
- **Codex:** use native agents in `~/.codex/agents/` (see `env-compat.md`).
<!-- /PLATFORM:CODEX -->

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

**TDD hard gate before any review:**
A `DONE` or `DONE_WITH_CONCERNS` report is only valid if it includes:
- RED evidence: failing command + failing assertion/exit code, or `RED: N/A` with a task-specific justification for truly non-behavioral work
- GREEN evidence: passing verification command(s) with exit code(s)

If RED evidence is missing or hand-wavy, stop with `BLOCKED_TDD_PROTOCOL`. Do not continue to spec review.

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

<!-- PLATFORM:CURSOR -->
**Async mode (Codex App, Cursor — no AskUserQuestion):**
- Set task to BLOCKED
- Propagate BLOCKED_BY_DEPENDENCY to dependent tasks (per Dependency State Contract)
- Continue executing any PENDING tasks that are NOT blocked by this dependency
- Include all BLOCKED tasks with their blockers in the final summary
- Do NOT wait inline — the pipeline continues on independent branches
- Print: `[AUTO-DECISION]: Task N blocked. Continuing with independent tasks. Review BLOCKED tasks in the final summary.`
<!-- /PLATFORM:CURSOR -->

### Step 4: Dispatch Spec Reviewer

Dispatch per environment:
- **Claude Code:** use the Task tool.
<!-- PLATFORM:CODEX -->
- **Codex:** use native agents in `~/.codex/agents/`.
<!-- /PLATFORM:CODEX -->

```
Agent: Spec Reviewer
  model: "sonnet"
  type: "Explore"
  instructions: read agents/spec-reviewer.md
  input: task spec from plan, spec document, list of files implementer created/modified,
         CODESIFT_AVAILABLE, repo identifier
```

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
<!-- PLATFORM:CODEX -->
- **Codex:** use native agents in `~/.codex/agents/`.
<!-- /PLATFORM:CODEX -->

```
Agent: Quality Reviewer
  model: "sonnet"
  type: "Explore"
  instructions: read agents/quality-reviewer.md
  input: list of production files modified, list of test files modified,
         CODESIFT_AVAILABLE, repo identifier, content of shared/includes/quality-gates.md
```

The quality reviewer applies CQ1-CQ29 on production code and Q1-Q19 on test code from the provided quality-gates.md. It also checks file size limits. For complex tasks, it verifies the test contract was filled correctly (all branches listed, no implementation-derived expected values, all mutations have catching tests).

### Step 7: Handle Quality Reviewer Verdict

#### PASS

Proceed to adversarial review (step 7b).

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
git add -u && git diff --staged | adversarial-review --mode code --artifact ".zuvo/context/adversarial-task-<task-N>.txt"
```

Mode selection:
- default task -> `--mode code`
- auth / tenant / payment / crypto / PII -> `--mode security`
- migrations / schema / DDL -> `--mode migrate`

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

The captured artifact path is mandatory for commit gating. Use the current task number in the filename:
- Task 1 -> `.zuvo/context/adversarial-task-1.txt`
- Task 9 -> `.zuvo/context/adversarial-task-9.txt`

Wait for complete output. Then:
- **Binary unavailable / no verdict produced** → `BLOCKED_ADVERSARIAL_UNAVAILABLE`. Do not commit.
- **CRITICAL** → re-dispatch implementer to fix, re-run quality reviewer, then re-run adversarial on the updated staged diff.
- **WARNING** (< 10 lines, localized) → re-dispatch implementer to fix, re-run quality reviewer, then re-run adversarial.
- **WARNING** (large/cross-file) or **INFO** → proceed only if logged as known concerns (max 3, one line each) and persisted to backlog.

**Retry limit:** Maximum 3 adversarial iterations per task. After 3 unresolved runs, stop with `BLOCKED_ADVERSARIAL_LOOP` and surface the exact findings to the user.

### Step 7c: Self-Review Gate + Branch Drift Check

Before committing, verify the task still satisfies the required gate order:

- multi-agent mode: implementer `DONE*` -> spec review `COMPLIANT` -> quality review `PASS` -> adversarial verdict recorded
- single-agent mode: `[GATE: spec-compliance]`, `[GATE: cq-critical]`, and `[GATE: adversarial-done]` must all be present

If any gate marker or verdict is missing: stop with `BLOCKED_MISSING_GATE`.

Then compare branches:

```bash
git branch --show-current
```

If the current branch differs from `branch:` in `.zuvo/context/execution-state.md`:
- stop with `BLOCKED_BRANCH_MISMATCH`
- print both branch names
- require an explicit user/runtime decision before committing on the new branch

If the branch change was intentional, update `branch:` during Step 9 and note it in task telemetry.

### Step 7d: Acceptance Proof (MANDATORY — the behavior gate)

Spec-review checks **textual compliance with plan** (did you implement what the plan said). Quality-review checks **code health gates** (CQ/Q). Adversarial review checks **diff text for hazards**. None of those check that **behavior matches Acceptance Criteria** when the code is actually exercised. This step does.

Read `../../shared/includes/acceptance-proof-protocol.md` for the surface taxonomy and proof shapes if not already loaded.

For the current task:

1. **Read the task's `Acceptance Proof:` block from the plan.** It lists one or more AC ids, each with `Surface`, `Proof`, `Expected`, `Artifact` fields.

2. **For each AC in the block:**
   - Set up preconditions (fixtures, env vars, seeded data) listed in the proof block.
   - Run the proof procedure exactly as written:
     - `backend-logic` / `api` / `integration` / `config` — execute the shell command or HTTP call. Capture stdout/stderr + exit code to `Artifact:` path.
     - `db` / `db-data` — run migration / sample query, capture schema dump or query results to artifact.
     - `ui` — drive Playwright or chrome-devtools MCP through the interaction script. Save screenshot + DOM snapshot to artifact.
     - `docs` — run linter / link checker, capture report.
   - Compare actual output against `Expected:` field.
   - If actual matches Expected → mark AC#x VERIFIED. If not → AC#x BROKEN with one-line observed-vs-expected.

3. **Independence requirement.** In multi-agent mode, dispatch a separate Acceptance Verifier agent (Sonnet, Explore type) given ONLY the task spec, the proof block, and access to run the proof. The verifier must NOT receive the implementer's status report. In single-agent mode, print `[CHECKPOINT: switching to acceptance-verifier role]` and treat the proof execution as a separate pass that does not trust implementation claims.

4. **LLM-judge fallback for UI subjective dimensions.** If the AC includes a subjective visual quality the proof cannot deterministically assert (e.g., "chip renders with affordance suggesting atomic edit"), after capturing the screenshot dispatch a Sonnet judge with `(AC text, screenshot path, DOM snapshot)` and require a binary `VERIFIED` / `BROKEN` token plus a one-sentence justification. Default to deterministic — only invoke judge when AC truly demands subjective measurement.

5. **Verdict:**
   - All ACs VERIFIED → emit `[GATE: acceptance-verified] <ac-ids> artifact=<paths>` and proceed to Step 8.
   - Any AC BROKEN → re-dispatch the implementer with the BROKEN list and observed-vs-expected detail. Re-run from Step 4 (spec review) on the next iteration. Maximum 3 acceptance iterations per task. After 3 unresolved iterations, mark BLOCKED with `BLOCKED_ACCEPTANCE_PROOF_FAILURE` and surface to user.
   - Proof cannot run (missing precondition, broken environment) → BLOCKED with `BLOCKED_PROOF_PRECONDITION_FAILED`. Do not commit the task — fixing preconditions is the next action.

6. **Artifact retention.** Every successful proof writes to `.zuvo/proofs/task-<N>-<ac-id>.<ext>`. The path is recorded in telemetry's `acceptance-verified` field for retro and audit. Failed proofs write to the same path with a `.failed` suffix and are kept for the implementer's re-dispatch context.

**No `[GATE: acceptance-verified]` marker = task remains IN_PROGRESS, no commit allowed.**

### Step 8: Commit

Only after spec review (COMPLIANT), quality review (PASS), and adversarial review (NO ISSUES or non-critical only), the orchestrator creates the commit:

1. Stage only the files listed in the task's "Files" field: `git add <file1> <file2> ...`
2. Never use `git add -A` or `git add .`
3. Verify `.zuvo/context/adversarial-task-<task-N>.txt` exists, is non-empty, and is newer than the latest staged edit for this task
4. Commit with the message from the task's Commit step
5. The implementer does NOT commit — it only writes files and runs verification

### Step 9: Write Session State Immediately

MANDATORY: Rewrite `.zuvo/context/execution-state.md` immediately after each successful commit using the WRITE protocol from `session-state.md`.

This is the only resumable artifact. If context is compacted, lost, or the session crashes, `execution-state.md` is the source of truth. Failure to rewrite it is a blocking bug. Treat it exactly like a failed test.

Also append this task to `## Completed Work Units` in `.zuvo/context/project-context.md`. If the branch changed intentionally for this task, update the stored `branch:` value at the same time.

### Step 9b: Mark Completed + Emit Telemetry

Print to the user:

```
--- Task N/M: [Task Name] ---
Status: COMPLETED
Files changed: [list]
Mode: [multi-agent|single-agent] (fallback: [none|reason])
Spec review: COMPLIANT (iteration [N])
Quality review: PASS (CQ: [score]/29, Q: [score]/19)
Adversarial review: [PASS / N findings (N critical) / BLOCKED]
Verify: [command -> exit code]
```

Then print the task telemetry block from `Required Telemetry`.

### Step 10: Update Project Context + Optional CodeSift Reindex

If CodeSift is available, call `index_file(path)` for each created or modified file after the task commit. This is maintenance, not a release gate.

If CodeSift is unavailable or reindex fails:
- record `codesift=unavailable` or `codesift=index-failed` in telemetry
- continue without warning spam

Do NOT run a `search_symbols()` spot-check as a completion gate.

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
2. If it fails again and single-agent mode is allowed in the current runtime: print the mandatory `[MODE SWITCH]` notice, record `fallback-path=agent-failure`, and continue in single-agent mode for the current task
3. If it fails again and single-agent mode cannot satisfy the required gates: mark the task as BLOCKED with reason "Agent failure after retry"
4. Present to the user with the standard 3 options (context, skip, abort)

Do not retry more than once. Two failures on the same dispatch indicate a systemic issue.

---

## After All Tasks Complete

### Phase Final: Whole-feature Smoke Proofs (MANDATORY before COMPLETED)

Per-task acceptance proofs verify each task's slice in isolation. They cannot detect **structural bugs that span multiple tasks** — e.g., the 2026-04-22 codec session where R-1 (validate Set dedup) and R-2 (data loss in stripRedundantVoidCloses) crossed three different tasks (encode, strip, decode) and only manifested when the full encode → transform → decode round-trip ran. Per-task gates passed; structural bug remained.

**Phase Final closes that gap.**

1. **Read the plan's `## Whole-feature Smoke Proofs` section.** It lists one or more SMOKE-id entries, each with `Preconditions`, `Proof`, `Expected`, `Artifact`.

2. **If the section says "Not applicable"** with a justification (e.g., internal subsystem with no end-user flow), accept it and skip to Session State Close. Note `smoke=skipped reason=<text>` in final telemetry.

3. **Otherwise, for each SMOKE proof:**
   - Set up the preconditions (typically heavier than per-task: full fixture set, seeded DB, dev server, sample input file).
   - Run the proof end-to-end. This is **not** a task-level test — it exercises the entire user flow described in the spec.
   - Capture artifact to `.zuvo/proofs/smoke-<flow-name>.<ext>`.
   - Compare against Expected invariants.
   - VERIFIED → next smoke. BROKEN → enter recovery loop (step 4).

4. **Smoke failure recovery.** A failed Whole-feature Smoke means tasks individually passed but the feature does not work end-to-end. Do NOT mark the plan COMPLETED. Instead:
   - Identify which AC the failing smoke maps to and which tasks claimed to satisfy that AC.
   - Re-dispatch the implementer for the most likely affected task with the smoke's observed-vs-expected output as failure context.
   - Re-run the affected task's Step 4 (spec review) onward.
   - After the task re-passes per-task gates, re-run the failed smoke.
   - Maximum 3 smoke iterations per failed SMOKE id. After 3, BLOCKED with `BLOCKED_WHOLE_FEATURE_SMOKE_FAILURE` and surface to user with the full observed-vs-expected report.

5. **Verdict:**
   - All SMOKE proofs VERIFIED (or "Not applicable" justified) → emit `[GATE: smoke-verified] <smoke-ids> artifact=<paths>` and proceed to Session State Close.
   - Any unresolved BROKEN after 3 iterations → plan does NOT transition to COMPLETED. Final summary lists the failing smoke with its observed-vs-expected.

**The plan cannot transition to `status: completed` without `[GATE: smoke-verified]` or an explicit "Not applicable" with a recorded justification.**

### Session State Close

Set `status: completed` in `.zuvo/context/execution-state.md`. Update `.zuvo/plans/active-plan.md` to `status: completed`.

The files remain on disk — they serve as a record of what was done. `zuvo:execute` will detect `status: completed` on next run and start fresh rather than attempting to resume.

### Final Summary

Print a completion report:

```
## Execution Complete

**Plan:** [plan document path]
**Tasks:** N completed, M skipped, K blocked
**Adversarial coverage:** X / N tasks
**Mode shifts:** [none | Task N -> single-agent (reason)]

### Task Results
| # | Task | Status | CQ Score | Q Score | Notes |
|---|------|--------|----------|---------|-------|
| 1 | [name] | COMPLETED | 26/29 | 17/19 | — |
| 2 | [name] | COMPLETED | 27/29 | 16/19 | Concern: [brief] |
| 3 | [name] | SKIPPED | — | — | Blocker: [brief] |

### Files Changed
[list all files created, modified, or deleted across all tasks]

### Backlog Items Added
[list any new items persisted to backlog during execution]

### Verification Evidence
[task -> command(s) -> exit code(s)]
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
- Adversarial WARNING / INFO findings that were intentionally deferred
- Any issues surfaced to the user that were deferred

For each finding:
1. Compute fingerprint: `file|rule-id|signature`
2. Check for duplicates in existing backlog
3. Route by confidence (0-25 discard, 26-50 backlog only, 51+ report and backlog)

### Retrospective (REQUIRED — no opt-out)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.

**The "trivial session" opt-out is removed.** Every execute run produces a retro entry. If the run truly was uneventful, the entry is brief (one Friction line of `none observed (single-task, all green)`) but must still exist. The 92% retro skip rate observed in 2026-Q1 left the pipeline blind to its own failure modes — every commit-without-retro is a defect we cannot learn from. No more.

### Worktree Suggestion

If the current working directory is inside a git worktree (check `git worktree list`), suggest:

"Execution is complete. You are working in a worktree. Run `zuvo:worktree` to finish — merge, push as PR, keep, or discard."

## Completion Gate Check

Before printing the final summary, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK (per task):
[ ] Spec reviewer ran (or [GATE: spec-compliance] marker printed)
[ ] Quality reviewer ran with PER-FILE scores (or [GATE: cq-critical] marker — aggregate scores forbidden)
[ ] Adversarial review ran
[ ] Acceptance proof ran for each AC the task claims (or [GATE: acceptance-verified] with artifact paths)
[ ] execution-state.md rewritten immediately after commit (not batched)

COMPLETION GATE CHECK (final):
[ ] Whole-feature Smoke Proofs ran (or [GATE: smoke-verified] / explicit "Not applicable" with justification)
[ ] Final summary table printed with all tasks AND all smoke proofs
[ ] Backlog persistence ran for deferred findings
[ ] Knowledge curation ran
[ ] Retrospective ran (no "trivial session" opt-out — every run produces a retro entry)
[ ] Run: line printed and appended to log
```

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
- CQ1-CQ29 on production code (critical gates: CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 + conditional: CQ16, CQ19-CQ24, CQ28)
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
| Adversarial review loop | 3 iterations | Mark BLOCKED, surface findings |
| Agent crash/timeout | 1 retry | Mark BLOCKED, present to user |

---

## What You Must NOT Do

- In multi-agent mode: do not write code yourself. Dispatch agents for all implementation work. In single-agent mode: write code yourself but follow the checkpoint protocol (Execution Modes section).
- Do not silently switch from multi-agent to single-agent. Announce the mode switch and keep every gate.
- Do not skip spec review or quality review. Both are mandatory for every task.
- Do not skip adversarial review. It is mandatory for every task.
- Do not silently skip BLOCKED tasks. Always present to the user with options.
- Do not proceed past a critical gate failure without user authorization.
- Do not auto-resolve disagreements between reviewers and implementers after 3 cycles. The user decides.
- Do not re-order tasks in a way that violates dependency constraints.
- Do not mark a task as completed if its tests have not been verified as passing.
- Do not start the next task until `execution-state.md` has been successfully rewritten on disk.
