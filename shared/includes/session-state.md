# Session State

Persist execution progress so sessions can resume after context compaction, crashes, or interruption.
State files live in `.zuvo/context/` in the project root. They are local runtime state — never committed.

---

## State Files

### `.zuvo/context/execution-state.md`

Written by `zuvo:execute` after each completed task. The primary source of truth for resume.

```markdown
# Execution State
<!-- session-id: <slug-YYYYMMDD-HHMM> -->
<!-- started-at: <ISO-8601> -->
<!-- last-updated: <ISO-8601> -->
<!-- status: in-progress | completed | aborted -->

plan: <path to plan file>
spec_id: <spec_id from plan header>
branch: <git branch at execution start>
total-tasks: <N>

## Progress
completed: [<task numbers>]
skipped: []
blocked: []
next-task: <N>

## Task Reasons
<!-- task-N: <reason-code> (<detail>) -->
<!-- task-3: skipped-dependency (blocked by task-2 failure) -->
<!-- task-4: blocked-build-failure (vitest run: 3 failures) -->
<!-- task-5: skipped-user (user chose skip at blocker prompt) -->

## Retry Counts
<!-- task-N.stage: <count> -->
<!-- task-3.spec-review: 2 -->
<!-- task-3.quality-review: 1 -->
<!-- task-3.adversarial: 0 -->
```

**Reason codes for Task Reasons:**

| Code | Meaning |
|------|---------|
| `skipped-user` | User explicitly chose to skip at a BLOCKED prompt |
| `skipped-dependency` | A prerequisite task was BLOCKED or SKIPPED |
| `blocked-build-failure` | Test/lint/type-check failed and could not be resolved |
| `blocked-external` | Missing external dependency, credential, or environment |
| `blocked-ambiguous` | Spec too ambiguous to proceed, escalated to user |
| `blocked-agent-crash` | Agent failed twice with no output |

**Retry stages:**
Track retries per task per stage: `task-N.spec-review`, `task-N.quality-review`, `task-N.adversarial`, `task-N.implementer`. Add new stages as the workflow evolves — the format is extensible.

---

### `.zuvo/context/project-context.md`

Written by `zuvo:execute` at startup. Passed to every agent dispatch.

> **Note:** Keep this file concise. It is a working aide, not a source of truth. Agents must verify repo structure with actual files when in doubt — never trust this file blindly.

```markdown
# Project Context
<!-- session-id: <same as execution-state.md> -->
<!-- last-updated: <ISO-8601> -->

stack: <detected stack>
test-runner: <exact command, e.g. "npx vitest run">
codesift-repo: <repo identifier or "unavailable">

## Completed Work Units (last 20)
<!-- Most recent first. Cap at 20 entries — remove oldest when over limit. -->
- Task <N>: "<name>" [<sha7>] — <files changed>

## Active Concerns (max 10)
<!-- Remove oldest INFO entries first when over limit. -->
- [<SEVERITY>] <file>:<line>: <one-line description>
```

**Growth control:**
- `## Completed Work Units`: cap at 20 entries, most recent first. When adding entry 21, remove the oldest.
- `## Active Concerns`: cap at 10 entries. When over limit, remove oldest INFO entries first, then oldest WARNING.
- If the file would exceed ~200 lines: trim oldest Completed Work Units before writing.

**Lifetime:** Survives across sessions. On fresh start, update `session-id` and continue accumulating. The history is valuable across sessions — do not wipe it on fresh start.

---

### `.zuvo/plans/active-plan.md`

Written by `zuvo:plan` after user approval. Used only for fresh-start plan discovery.

```markdown
# Active Plan
<!-- approved: <ISO-8601> -->
<!-- status: pending | in-progress | completed -->

plan: <path to plan file>
spec_id: <spec_id>
tasks: <N>
```

---

## Precedence (source of truth order)

When multiple signals exist, use this order:

```
1. execution-state.md (status: in-progress)  → RESUME
2. active-plan.md (status: pending)           → FRESH START with known plan
3. Normal Glob discovery                       → FRESH START with Glob
```

If `execution-state.md` (in-progress) and `active-plan.md` point to **different plans**:
- Trust `execution-state.md` — it reflects actual work done.
- Print: `[WARN] active-plan.md points to a different plan than execution-state.md. Using execution-state.md as source of truth.`

---

## READ Protocol (execute startup)

**Step 1: Check for execution-state.md**

```
Read(".zuvo/context/execution-state.md")
```

If missing → skip to Step 3.

If `status: in-progress` → proceed to Step 2 (validate before trust).

If `status: completed`:
- Print: `[SESSION] Prior session completed. Starting fresh.`
- Rename: `execution-state.md` → `execution-state.completed` (keep as record)
- Proceed to Step 3.

If `status: aborted`:
- Print: `[SESSION] Prior session aborted at Task <next-task>. Starting fresh.`
- Rename: `execution-state.md` → `execution-state.stale` (keep for diagnosis)
- Proceed to Step 3.

**Step 2: Validate state before trusting it**

Run all checks. If ANY check fails: mark state as stale and start fresh.

| Check | Pass condition | On fail |
|-------|---------------|---------|
| Plan file exists | `Read(state.plan)` succeeds | Stale |
| spec_id matches | `plan.spec_id == state.spec_id` | Stale |
| total-tasks matches | `plan.task_count == state.total-tasks` | Stale |
| next-task is valid | `state.next-task <= state.total-tasks` | Stale |
| Branch matches | `git branch --show-current == state.branch` | Warn only |

**Branch mismatch:** Do NOT mark stale. Print:
```
[WARN] Branch mismatch: state was recorded on '<stored-branch>', current branch is '<current-branch>'.
       Resuming anyway — verify this is intentional.
```

**On stale state:**
1. Rename: `execution-state.md` → `execution-state.stale`
2. Print:
   ```
   [SESSION] Stale state detected — <specific reason>.
             Renamed to .zuvo/context/execution-state.stale for diagnosis.
             Starting fresh.
   ```
3. Proceed to Step 3.

**On valid state:**

Resume mode:
```
[RESUME] In-progress session detected.
  Session:   <session-id>
  Started:   <started-at>
  Plan:      <plan path>
  Progress:  Tasks [<completed>] done, next: Task <next-task>
  Branch:    <branch>

Resuming from Task <next-task>. Completed tasks will be skipped.
```

Load:
- Plan from `state.plan` (skip Glob).
- Stack/test-runner from `.zuvo/context/project-context.md`.
- Retry counts from `## Retry Counts`.
- Skip all tasks in `completed[]`, `skipped[]`.
- Restore blocked tasks and their reasons.
- Continue execution from `next-task`.

**Step 3: Check active-plan.md (fresh start only)**

```
Read(".zuvo/plans/active-plan.md")
```

If exists and `status: pending`: use `plan:` field. Skip Glob.
If exists and `status: in-progress` or `status: completed`: ignore, fall through to Glob.
If missing: fall through to Glob.

---

## WRITE Protocol (execute — session initialization)

Before the first agent dispatch, generate a session identity and initialize all state files.

**Generate session-id:**
```
session-id: exec-<YYYYMMDD>-<HHMM>
```
Example: `exec-20260407-1423`

**Write `.zuvo/context/execution-state.md`:**
- `session-id`: generated above
- `started-at`: now (ISO-8601)
- `status: in-progress`
- `total-tasks`: from plan
- `completed: []`, `skipped: []`, `blocked: []`
- `next-task: 1`

**Write/update `.zuvo/context/project-context.md`:**
- Update `session-id` to current session
- Update `last-updated`
- Keep existing `## Completed Work Units` and `## Active Concerns` (accumulate across sessions)
- Update `stack`, `test-runner`, `codesift-repo` (re-detect fresh)

**Update `.zuvo/plans/active-plan.md`:**
- Set `status: in-progress`

**Ensure `.zuvo/` in `.gitignore`:** Check `.gitignore`; if `.zuvo/` not present, append:
```
# zuvo session state (local runtime, not committed)
.zuvo/
```

---

## WRITE Protocol (execute — after each task)

**After Step 9 (Mark Completed):**

Rewrite `.zuvo/context/execution-state.md` (full rewrite — never append):
- Add task number to `completed[]`
- Update `next-task` to lowest PENDING task
- Update `last-updated`
- Append to `## Files Changed` (keep for diagnosis)

Append to `.zuvo/context/project-context.md` → `## Completed Work Units`:
```
- Task <N>: "<name>" [<sha7>] — <comma-separated files>
```
Trim to last 20 entries if over limit.

**After a task is SKIPPED:**
- Add to `skipped[]`
- Add to `## Task Reasons`: `task-N: <reason-code> (<detail>)`
- Update `next-task`

**After a task is BLOCKED:**
- Add to `blocked[]`
- Add to `## Task Reasons`: `task-N: <reason-code> (<detail>)`
- Do NOT update `next-task` if this task IS `next-task` — leave pointing at blocked task

**After adversarial review (Step 7b), WARNING/INFO findings:**
Append to `## Active Concerns` in project-context.md:
```
- [WARNING] <file>:<line>: <description>
```
Trim to 10 entries (remove oldest INFO first).

**On all tasks complete:** Set `status: completed`. Update active-plan.md to `status: completed`.

**On user abort:** Set `status: aborted`.

---

## WRITE Protocol (plan — after approval)

After user approves the plan, write `.zuvo/plans/active-plan.md`:

```bash
mkdir -p .zuvo/plans
```

Fields: `plan`, `spec_id`, `tasks`, `approved` (timestamp), `status: pending`.

---

## Cleanup Reference

| Event | execution-state.md | project-context.md | active-plan.md |
|-------|-------------------|-------------------|----------------|
| All tasks complete | → `execution-state.completed` | Keep, update session-id | `status: completed` |
| User abort | → `execution-state.stale` | Keep as-is | Unchanged |
| Stale validation fail | → `execution-state.stale` | Keep as-is | Unchanged |
| Fresh start (next execute) | Writes new file | Updates session-id, appends history | `status: in-progress` |

Stale/completed files are kept for diagnosis. They do not interfere — READ protocol ignores non-`in-progress` files.
