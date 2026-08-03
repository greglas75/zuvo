# Session State

Persist execution progress so sessions can resume after context compaction, crashes, or interruption.
State files live in `zuvo/context/` in the project root. They are local runtime state — never committed.
For `zuvo:execute`, rewriting `execution-state.md` after each successful commit is a blocking
durability step, not a best-effort note. That blocking rule is specific to the resume state files —
`task-telemetry.jsonl` is a diagnostic append whose failure is a WARNING; see its own section.

---

## State Files

### `zuvo/context/execution-state.md`

Written by `zuvo:execute` immediately after each successful task commit. The primary source of truth for resume.
If this file is not rewritten, the task is not durably complete.

```markdown
# Execution State
<!-- session-id: <slug-YYYYMMDD-HHMM> -->
<!-- started-at: <ISO-8601> -->
<!-- last-updated: <ISO-8601> -->
<!-- status: in-progress | completed | aborted -->

plan: <path to plan file>
spec_id: <spec_id from plan header>
branch: <current execution branch>
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
<!-- Only non-zero values. Omit stages with zero retries to keep the file compact. -->
<!-- task-N.stage: <count> -->
<!-- task-3.spec-review: 2 -->
<!-- task-3.quality-review: 1 -->

## Files Changed
<!-- Appended after each successful task commit. Diagnostic only — not used for resume logic. -->
- <file> (Task <N>, commit <sha7>)

## Retro State
<!-- retro-session-id is the stable identity of THIS RUN (the plan execution), -->
<!-- assigned ONCE at run start and persisted here. It is NOT the per-process -->
<!-- session-id: a resuming process INHERITS this value unchanged (it does not -->
<!-- regenerate it), so the whole multi-session run finalizes ONE retro. -->
<!-- Resume rule (see READ Protocol "Retro carry"): the resuming run adopts the -->
<!-- persisted retro-session-id; its single eventual full retro is keyed to it. -->
<!-- A checkpoint stub for this run is superseded by this run's full retro -->
<!-- (retro-stub idempotency on skill+project+SHA7 is the cheap WITHIN-run -->
<!-- guard). Distinct runs (different retro-session-id — e.g. two runs on the -->
<!-- same commit) each keep their OWN retro: no cross-run dedup, no data loss. -->
<!-- retro-session-id: <stable id owning this run's eventual retro; inherited on resume> -->
<!-- last-retro-status: none | stub:ABANDONED | stub:CONTEXT_OUT | stub:PARTIAL | full -->
<!-- last-retro-friction: <FRICTION_CATEGORY enum value, or - > -->
```

**Reason codes for Task Reasons** (required for skipped/blocked tasks, optional for completed tasks):

| Code | Meaning |
|------|---------|
| `skipped-user` | User explicitly chose to skip at a BLOCKED prompt |
| `skipped-plan-declared` | The task hit a hard blocker and its plan task declared **Failure:** skip-and-continue |
| `skipped-dependency` | A prerequisite task was BLOCKED or SKIPPED |
| `blocked-build-failure` | Test/lint/type-check failed and could not be resolved |
| `blocked-external` | Missing external dependency, credential, or environment |
| `blocked-ambiguous` | Spec too ambiguous to proceed, escalated to user |
| `blocked-agent-crash` | Agent failed twice with no output |

**Retry stages:**
Track retries per task per stage: `task-N.spec-review`, `task-N.quality-review`, `task-N.adversarial`, `task-N.implementer`. Add new stages as the workflow evolves — the format is extensible. Omit zero-value stages — only record stages that actually had retries. A fresh start initializes all retry counts empty; prior counts remain only in archived `.stale`/`.completed` files.

**Task exclusivity:** A task may appear in only one terminal bucket: `completed[]`, `skipped[]`, or `blocked[]`. Never in two or more simultaneously.

---

### `zuvo/context/project-context.md`

Written by `zuvo:execute` at startup. Passed to every agent dispatch.

> **Note:** Keep this file concise. It is a working aide, not a source of truth. Agents must verify repo structure with actual files when in doubt — never trust this file blindly.

```markdown
# Project Context
<!-- last-session-id: <session-id of the most recent session using this file> -->
<!-- last-updated: <ISO-8601> -->

repo_root: <absolute path of the tree this plan executes in — the targeted worktree, NOT necessarily the session CWD; resolved at execute's worktree pre-flight and passed to every sub-agent so multi-agent is path-safe>
branch: <execution branch>
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

**Lifetime:** Survives across sessions. On fresh start, update `last-session-id` to the current session and continue accumulating. The history is valuable across sessions — do not wipe it on fresh start.

**If project-context.md is missing or malformed:** Rebuild it from scratch (re-detect stack, test-runner, codesift-repo). Do not fail resume because of project-context corruption — this file is a convenience aide, not a resume requirement.

---

### `zuvo/plans/active-plan.md`

Written by `zuvo:plan` after user approval. Used for fresh-start plan discovery **and read by a
git hook** — see the format contract below.

```markdown
# Active Plan
status: pending | in-progress | completed
plan: <path to plan file>
spec_id: <spec_id>
tasks: <N>
approved: <ISO-8601>
```

**The format is a contract, not cosmetics.** `hooks/lib/refactor-gate-lib.sh ::
plan_execute_gate_check` parses `status:` and `plan:` from this file on every AI commit and
push. It fail-OPENs when it cannot read them — silently, with no warning. This file previously
documented `<!-- status: ... -->` while the gate read only a plain `status:` line, so 8 of 19
real repos had a completely dead plan→execute gate.

- Write `status:` and `plan:` as **plain lines**, exactly as above. Do not wrap them in an HTML
  comment, and do not rename `plan:` to `plan_file:`.
- The gate now also *accepts* the `<!-- status: -->` and `plan_file:` variants so existing repos
  keep working, but new writes must use the canonical form.
- `zuvo/plans/active-plan.md` is **local runtime state** (gitignored) — but a stale
  `status: in-progress` pointer left behind after a finished run is not free: the gate treats
  uncorroborated `in-progress` as `pending`. Set it to `completed` when the run ends.
- Verify what the gate actually sees with `scripts/zuvo-phase.sh status` (or `doctor`).

Note the contrast with `execution-state.md` above, which keeps the `<!-- status: ... -->`
comment form: `hooks/pre-commit-adversarial-gate.sh` matches that literal string. The two files
deliberately use different dialects; do not "harmonize" one without updating its reader.

---

### `zuvo/context/task-telemetry.jsonl`

Written by `zuvo:execute` at the end of Step 9b — one JSON line per finished task, carrying the
same fields as the printed `[TELEMETRY]` block. Before this file existed the block was printed to
chat and then lost, so nothing downstream (`zuvo:retro`, gate-failure trends, reviewer-route
distribution) could ever read it.

```jsonl
{"at":"2026-08-02T10:00:00Z","session-id":"exec-20260802-1000","retro-session-id":"retro-20260802-1000","task":4,"task-name":"Tenant extension hardening","surface":"api","mode":"multi-agent","fallback-path":"none","writer-model":"opus","reviewer-route":"review-alt","implementer-status":"DONE","spec-review":"COMPLIANT","quality-review":"PASS cq=34/37@tenant.ts,35/37@guards.ts q=22/24@tenant.test.ts","adversarial":"PASS mode=code","verify":"npx vitest run src/tenant.spec.ts exit=0","acceptance-verified":["AC2@zuvo/proofs/task-4-report.md","AC5@zuvo/proofs/task-4-report.md"],"codesift":"available","backlog-adds":1,"failure-strategy":"halt"}
```

**Field contract — exactly these 19 keys, in this order, on every record.** This table is the
schema's single source of truth: `tests/skill-suite/test-task-telemetry-contract.sh` derives the
key list from it and diffs it against the writer's own list, so the two cannot drift. The
`zuvo:telemetry-schema` markers are the parser's bounds — prose, a `---` rule, or another table in
this section can never truncate the schema it sees. Add rows inside the markers, never outside.

<!-- zuvo:telemetry-schema:start -->

| Key | Type | Meaning |
|-----|------|---------|
| `at` | string | ISO-8601 UTC timestamp of the append |
| `session-id` | string | The per-process session (`exec-<YYYYMMDD>-<HHMM>`). Changes on resume. |
| `retro-session-id` | string | Stable identity of the whole RUN. Inherited unchanged on resume — this is what stitches a resumed run's records back together. |
| `task` | int | Task number from the plan. **`-1` is the unsubstituted sentinel** — an impossible task number, so a forgotten substitution is visible instead of reading as a real "task 0". |
| `task-name` | string | Task name, verbatim (may contain quotes, em-dashes, commas) |
| `surface` | string | `backend-logic` \| `api` \| `db` \| `db-data` \| `ui` \| `integration` \| `config` \| `docs` |
| `mode` | string | `multi-agent` \| `single-agent` |
| `fallback-path` | string | `none` \| `dispatch-unavailable` \| `dispatch-disallowed` \| `agent-failure` \| `same-model-fallback` |
| `writer-model` | string | Implementer model/lane actually used |
| `reviewer-route` | string | `review-primary` \| `review-alt` \| `same-model-fallback` \| `routing-failed` |
| `implementer-status` | string | `DONE` \| `DONE_WITH_CONCERNS` \| `NEEDS_CONTEXT` \| `BLOCKED` |
| `spec-review` | string | `COMPLIANT` \| `ISSUES FOUND` |
| `quality-review` | string | The **full per-file** string exactly as printed (`PASS cq=34/37@a.ts,35/37@b.ts q=22/24@a.test.ts`). **Stored whole, never decomposed** into per-file sub-objects — a schema a reader has to reassemble is precisely how the aggregate collapse comes back. Per-file scoring is mandatory; see `skills/execute/SKILL.md` → Required Telemetry. |
| `adversarial` | string | Verdict plus mode, e.g. `PASS mode=code` |
| `verify` | string | Command(s) and exit code(s) |
| `acceptance-verified` | array of string | AC ids plus artifact paths, one element each (`["AC2@zuvo/proofs/task-4-report.md", ...]`). Empty array when none. **Written as ONE JSON array literal, never comma-split** — an AC id or an artifact path may legally contain a comma, and splitting turns one element into two silently. A value that does not parse as a JSON array degrades to `[]` rather than aborting the record. |
| `codesift` | string | `available` \| `unavailable` \| `index-failed` |
| `backlog-adds` | int | Backlog entries added by this task. **`-1` is the unsubstituted sentinel** — same reasoning as `task`; `0` would be a plausible real value. |
| `failure-strategy` | string | `halt` \| `skip-and-continue` \| `degraded:<desc>` — the task's declared failure strategy. **Defaults to `halt`, never null.** Defined here now; populated from the plan by a later change. |

<!-- zuvo:telemetry-schema:end -->

**APPEND-ONLY — one line per task.** This is the opposite of the rule that governs
`execution-state.md` ("full rewrite — never append", WRITE Protocol below). Do not read this file
before writing, do not rewrite it, do not truncate it. **The READ Protocol does not touch this file
and must not start to** — a resumed run *appends* its records after the ones already there; it never
rebuilds or replays them. A record is a fact about a task that finished; facts are not edited later.

**Accepted cost of append-only:** Step 10 runs after the append and can downgrade `codesift` to
`index-failed`. That later value is *not* back-written into the record. This is deliberate — moving
the write to Step 10 would put it inside an explicitly best-effort maintenance step, so a real
telemetry record would be lost every time reindexing was skipped.

**Output root — resolved exactly like `execution-state.md`'s:** `$ZUVO_OUTPUT_DIR`, else
`<git root>/zuvo` (`report-output-location.md`). **No `pwd` fallback:** if neither resolves the
writer takes the `[WARN]` path and writes nothing, because records dropped into whatever directory
the shell happened to sit in split one project's history across unrelated trees.

**Concurrent appends are locked.** `zuvo:execute` dispatches tasks in **parallel batches**, so two
appends can reach this file at once; the writer holds an exclusive `flock` across write+flush+fsync.
Unlocked, two records interleave inside one physical line and **both** are lost. A lock failure is a
`[WARN]` like every other failure here — never a gate. `fcntl` is POSIX-only, so on a platform where
it cannot be imported the writer persists the record unlocked instead of not at all — a lost record
is worse than a theoretically interleavable one, and a single-writer platform cannot race with itself.

**Reader contract — skip a malformed line, never abort on one.** Parse line by line, `continue` past
anything that does not parse, and count the skips. A kill between `write` and `fsync` can leave a
truncated **trailing** line (the lock prevents interleaved lines, not truncated ones), and a hand
edit can corrupt any line. The platform without `fcntl` above is the one place an *interleaved* line,
not just a truncated one, is possible — the same skip-and-count handling covers it without a special
case. Dying on a bad line turns a diagnostic into an outage; dropping one without saying so hides
data loss.

**Lifetime and retention:** the same as `project-context.md` — survives across sessions, **never
renamed, never truncated, no cap, no rotation**. That is a decision, not an omission: rotation means
rewriting (which APPEND-ONLY forbids) and truncation deletes the cross-session history the file
exists for, while growth is bounded by finished tasks — ~600 bytes each, under 2 MB/year at 50
tasks/week, streamed line by line by readers. A project that wants it smaller prunes with
`tail -n <N>` **by hand**, accepting the loss; no skill does it mid-run. Explicitly **NOT**
`execution-state.md`'s lifetime: the `.completed`/`.stale` rename in the Cleanup Reference would
split one resumed run's records across two files.

**Gitignored for free** — it lives under `zuvo/`, which the WRITE Protocol already ensures is in
`.gitignore`. No separate ignore rule is needed.

**If the append fails: WARN and continue.** A failed append is **not** a failed test, **not** a
`BLOCKED_*` state, and never halts or retries the task. The writer prints
`[WARN] task-telemetry append failed — continuing (diagnostic file, never a gate)` and execution
proceeds to Step 10. The unqualified rule *"Treat a failed rewrite exactly like a failed test"* in
the WRITE Protocol below governs **`execution-state.md` only** — that file is the resume source of
truth; this one is a diagnostic. Do not harden this into a gate.

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
Read("zuvo/context/execution-state.md")
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
             Renamed to zuvo/context/execution-state.stale for diagnosis.
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
- Plan from `state.plan` (skip Glob). **Ignore `active-plan.md` entirely on valid resume** — execution-state.md is the sole source of truth.
- Stack/test-runner from `zuvo/context/project-context.md` (if missing or malformed: re-detect, do not fail).
- Retry counts from `## Retry Counts`.
- **Retro carry (one RUN ⇒ one retro):** if `retro-session-id` is set, the
  resuming run **inherits it unchanged** (do NOT regenerate from the new
  process session-id) — this run owns that prior retro, so finalize/upgrade
  it and do NOT write a second. This run's full retro supersedes its own
  earlier checkpoint stub (retro-stub idempotency on `skill+project+SHA7` —
  the within-run guard). Distinct runs keep distinct `retro-session-id`s
  (two runs on the same commit each keep their own retro — no cross-run
  dedup, no data loss). One run yields exactly one eventual retro (stub OR
  full, never both).
- Skip all tasks in `completed[]`, `skipped[]`.
- Restore blocked tasks and their reasons.
- Continue execution from `next-task`.

**Step 3: Check active-plan.md (fresh start only)**

```
Read("zuvo/plans/active-plan.md")
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

**Write `zuvo/context/execution-state.md`:**
- `session-id`: generated above
- `started-at`: now (ISO-8601)
- `status: in-progress`
- `total-tasks`: from plan
- `completed: []`, `skipped: []`, `blocked: []`
- `next-task`: set to the lowest task number in the plan (usually 1, but do not hardcode)
- **Cross-repo plans only** — `repositories:` a list, one entry per repo the plan touches, each with
  `path`, `branch`, `base`, `head`, `review_artifact`, `pull_request`, `push_remote` and
  `required_checks`. A single `head`/`branch` at the top level cannot describe a plan spanning two
  repos, so a resumed run reconstructs the wrong one — and the review artifact, PR and checks are
  per-repo facts that get silently attributed to whichever repo was last touched. Omit the key
  entirely for the normal single-repo case; an empty list is not the same as absent.

**Write/update `zuvo/context/project-context.md`:**
- Update `last-session-id` to current session
- Update `last-updated`
- Keep existing `## Completed Work Units` and `## Active Concerns` (accumulate across sessions)
- Update `stack`, `test-runner`, `codesift-repo` (re-detect fresh)

**Update `zuvo/plans/active-plan.md`:**
- Set `status: in-progress`

**Ensure `zuvo/` in `.gitignore`:** Check `.gitignore`; if `zuvo/` not present, append:
```
# zuvo session state (local runtime, not committed)
zuvo/
```

---

## WRITE Protocol (execute — after each task)

**After Step 9 (successful commit):**

Rewrite `zuvo/context/execution-state.md` (full rewrite — never append):
- Add task number to `completed[]`
- Update `next-task` to lowest PENDING task (lowest number not in completed/skipped/blocked)
- Update `last-updated`
- Update `branch` if the session intentionally continued on a different branch than the previous task
- Append to `## Files Changed`: `- <file> (Task <N>, commit <sha7>)` for each changed file

Append to `zuvo/context/project-context.md` → `## Completed Work Units`:
```
- Task <N>: "<name>" [<sha7>] — <comma-separated files>
```
Trim to last 20 entries if over limit.

Append one record to `zuvo/context/task-telemetry.jsonl` at the end of Step 9b (see that file's
section above). Append-only; a failure there is a WARNING, never a gate.

MANDATORY (**`execution-state.md` only** — these three rules do NOT extend to
`task-telemetry.jsonl`, whose failure behaviour is a WARNING by contract):
- Rewrite the file immediately after each successful commit
- Treat a failed rewrite exactly like a failed test
- Do not start the next task until the file on disk reflects the new `completed[]`, `next-task`, and `last-updated` values

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

**On all tasks complete:** Set `status: completed`. Update active-plan.md to `status: completed`. The file stays as `execution-state.md` until the next startup renames it to `.completed`.

**On user abort:** Set `status: aborted`. Update active-plan.md to `status: aborted`. The file stays as `execution-state.md` until the next startup renames it to `.stale`.

---

## WRITE Protocol (plan — after approval)

After user approves the plan, write `zuvo/plans/active-plan.md`:

```bash
mkdir -p zuvo/plans
```

Fields: `plan`, `spec_id`, `tasks`, `approved` (timestamp), `status: pending` — each as a
**plain line**, per the format contract in the `active-plan.md` section above. A git hook parses
`status:`/`plan:` on every AI commit; an HTML-comment wrapper makes it unreadable and the gate
fail-opens silently. Confirm with `scripts/zuvo-phase.sh status` after writing.

---

## Cleanup Reference

| Event | execution-state.md | project-context.md | active-plan.md |
|-------|-------------------|-------------------|----------------|
| All tasks complete | `status: completed` (renamed to `.completed` on next startup) | Keep, update last-session-id | `status: completed` |
| User abort | `status: aborted` (renamed to `.stale` on next startup) | Keep as-is | `status: aborted` |
| Stale validation fail | Renamed to `.stale` immediately | Keep as-is | Unchanged |
| Fresh start (next execute) | Writes new file | Updates last-session-id, appends history | `status: in-progress` |

**`task-telemetry.jsonl` is absent from every row of that table on purpose.** No event above
touches it — not "all tasks complete", not "user abort", not "stale validation fail", not "fresh
start". It is **never renamed and never truncated** in any of them; a fresh run simply keeps
appending to the same file. Giving it a `.completed`/`.stale` rename like `execution-state.md`
would split one resumed run's records across two files and defeat the cross-session view the file
exists for. (The table is Event × File; this paragraph is that file's column, kept as a footnote so
the four-column table stays readable.)

**Rename timing:** Terminal states (`completed`, `aborted`) are written immediately but the file stays as `execution-state.md`. The rename to `.completed`/`.stale` happens on the **next startup** (READ protocol Step 1). Stale validation failures rename immediately (READ protocol Step 2).

Stale/completed files are kept for diagnosis. They do not interfere — READ protocol ignores non-`in-progress` files.
