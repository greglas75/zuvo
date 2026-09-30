---
name: test-audit
description: "Batch audit of test files against Q1-Q25 quality gates and AP1-AP32 anti-patterns. Detects orphan tests, phantom mocks, untested public methods. Tiered output (A/B/C/D) with critical gate enforcement and optional post-audit fix workflow. Flags: zuvo:test-audit all | [path] | [file] | --deep | --quick | --include-e2e | --details | --commit=ask|auto|off"
category: Code/Test audits
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # discover *.test.* / *.spec.* / __tests__/
    - get_file_outline
    - search_text
    - search_symbols           # untested public methods (production-side)
    - get_symbol
    - get_symbols
    - find_references          # orphan-test + untested-public-method detection (no AP id — this is the
                               #   pre-scan's ORPHAN/untested-methods signal, not an anti-pattern)
    - find_dead_code           # AP17 unused test data declared but never referenced
    - find_clones              # AP18 duplicate test names / copy-pasted test bodies
    - search_patterns
    - audit_scan
    - scan_secrets             # hardcoded credentials in fixtures (no AP id — a security finding,
                               #   reported separately from the AP deduction)
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan, resolve_php_namespace]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit]
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

# zuvo:test-audit — Test Quality Triage

Systematic evaluation of unit and integration test files through the Q1-Q25 binary checklist and AP anti-pattern catalog. Each test file is paired with its production source, scored against behavioral coverage standards, and assigned a tier.

**Scope:** Unit and integration tests only. E2E tests (`*/e2e/*`, `*.e2e.*`) are excluded by default. Use `--include-e2e` to include them.

**When to use:** After mass test writing, when test quality is uncertain, before releases, when test failures are hard to diagnose, periodic health check.
**Out of scope:** Single-file code review (use `zuvo:review`), writing new tests (use `zuvo:write-tests`), fixing systematic anti-patterns across many files (use `zuvo:fix-tests`).

## Argument Parsing

| Argument | Effect |
|----------|--------|
| `all` | Audit every test file in the project |
| `[path]` | Audit test files under a specific directory |
| `[file]` | Audit a single test file with full evidence (forces deep mode) |
| `[file file2 …]` | Audit exactly the listed test files (space-separated, forces deep mode) — the form the Test Quality Gate (`../../shared/includes/test-quality-gate.md`, called from build/refactor/execute/write-tests/write-e2e) uses to scope to touched files |
| `--deep` | Collect evidence and fix recommendations for every file |
| `--quick` | Binary pass/fail only, skip evidence |
| `--include-e2e` | Include E2E test files in scope |
| `--details` | Save per-file reports to `zuvo/audits/test-audit-details/` |
| `--commit=ask\|auto\|off` | Commit behavior after fix workflow (default: `ask`) |
| `--read-only` | Report only: skip Phases 4-6 (coverage.md/backlog.md writes) and Phase 7; no repo mutation beyond the `zuvo/audits/` report |

Default: `all --quick --commit=ask`

**Dispatch is already authorized — do not ask, and do not substitute.** Invoking this skill IS the
request for the gates it mandates. A session-level instruction like "do not use the Agent tool unless
the user asked" does NOT apply here: the user asked, by invoking this skill. Reading it as a
prohibition and recording a self-scored result is the substituted gate this step forbids — it
happened twice in the field (2026-08-07, 2026-08-08), the second time invented as
`WARN:substituted-inline`, a value no vocabulary defines. If the harness genuinely has no dispatch
capability (Cursor, Antigravity — NOT Codex, which dispatches mechanical workers), follow the ONE documented exception in
`test-quality-gate.md`; otherwise dispatch.


| Mode | Scope | Depth | Commit | Notes |
|------|-------|-------|--------|-------|
| `all` | Entire project | Standard | `--commit=ask` | Default |
| `[path]` | Directory | Standard | `--commit=ask` | Scoped |
| `[file]` | Single file | Deep | `--commit=ask` | Full evidence |
| `[file file2 …]` | Listed files only | Deep | `--commit=ask` | File-list scope (Test Quality Gate callers pass `--read-only --commit=off`) |
| `--deep` | Any scope | Full evidence + fixes | Per flag | Thorough |
| `--quick` | Any scope | Binary only | `--commit=off` | Fast triage |
| `--include-e2e` | + E2E files | Standard | Per flag | Expanded scope |
| `--details` | Any scope | + per-file reports | Per flag | Save individual files |

## Mandatory File Loading

First resolve `../../shared/includes/execution-policy.md` and
`../../shared/includes/evidence-reuse.md`. Reuse the parent policy and verified evidence for
a nested stage. Load only the rules needed now, with the read-once receipt protocol.

Load the applicable definitions using the read-once protocol. Defer logging/retro includes until completion.

```
CORE FILES LOADED:
   1. ../../rules/testing.md              -- READ/MISSING
   2. ../../shared/includes/test-edge-cases.md   -- READ/MISSING
   3. ../../shared/includes/env-compat.md -- READ/MISSING
   4. ../../shared/includes/run-logger.md -- READ/MISSING
   5. ../../shared/includes/retrospective.md -- READ/MISSING
   6. ../../shared/includes/no-pause-protocol.md -- READ/MISSING (HARD: no mid-batch pauses)
   7. ../../shared/includes/test-quality-gate.md -- READ/MISSING (carries the dispatch-authorization rule)
   8. ../../shared/includes/test-metrics.md -- READ/MISSING (frozen quality/cost/speed formulas — cite TIER_DIST/ECHO_COUNT, never restate)
   9. ../../shared/includes/test-audit-batch-prompt.md -- READ/MISSING (the Phase 1 batch agent prompt template)
```


**If any file is missing:** Stop. The quality gate definitions are required for scoring.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking.

## MANDATORY TOOL CALLS — Test Audit Validity Gate

**INVALID if any tool below is skipped when trigger holds.** "DEFERRED", "N/A", "--quick mode" NOT valid reasons.

| Tool | Trigger | Skip allowed? |
|------|---------|---------------|
| `find_dead_code` | Always | **NO** — AP17 unused test data |
| `find_clones` | Always | **NO** — AP18 duplicate test names / copy-pasted bodies |
| `find_references` | Always | **NO** — orphan tests + untested public methods (no AP id) |
| `search_patterns` | Always | **NO** — Q-checklist anti-patterns |
| `audit_scan` | Always | **NO** — compound check |
| `scan_secrets` | Always | **NO** — hardcoded credentials in fixtures (security, not an AP) |
| Stack-specific tools | Framework/language detected | **NO** when matches |

Forbidden: `find_dead_code: skipped`, `codesift: unavailable` (when deferred), `retrospective: skipped` — all REJECTED.

POSTAMBLE: report on disk → retro appended → `~/.zuvo/append-runlog` exit 0. Every Q-fail/AP finding needs `path/to/file.ext:LINE` (verify-audit gate).

```
Mandatory-tools-acknowledgment: I will run find_dead_code + find_clones + find_references + search_patterns + audit_scan + scan_secrets + stack-specific tools for this test audit. Every finding will cite a `path/to/file.ext:LINE` resolving in the current tree.
```

---

## CodeSift Integration

**Use the deterministic preload helper FIRST.** Run `~/.zuvo/compute-preload test-audit "$PWD"` before any ToolSearch. Copy `[CodeSift matching trace]` verbatim, issue printed `ToolSearch(query="select:...")`. Math gate enforced.

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift for file discovery and production code analysis when available. If unavailable, fall back to standard tools.

### CodeSift Optimizations

| Task | CodeSift | Fallback |
|------|----------|----------|
| Find test files | `get_file_tree(repo, name_pattern="*.test.*")` | `find` command |
| Understand test structure | `get_file_outline(repo, file_path)` | `Read` each file |
| Batch-read test cases | `get_symbols(repo, symbol_ids=[...])` | Multiple `Read` calls |
| Find production file for test | `search_symbols(repo, query, kind="function")` | Path-based heuristic |
| Verify test imports | `find_references(repo, symbol_name)` | `Grep` for imports |
| Pre-scan for weak assertions | `search_text(repo, "toBeTruthy\|toBeDefined", file_pattern="*.test.*")` | `Grep` |

### Degraded Mode (CodeSift unavailable)

All steps fall back to `find`/`Read`/`Grep`/`Glob`. File discovery is slower and production file pairing relies on path conventions rather than symbol resolution.

---

## Phase 0: Discovery and Pairing

### 0.1 Locate Test Files

When CodeSift is available: `get_file_tree(repo, name_pattern="*.test.*")` with path filters excluding `node_modules`, `.next`, `e2e` (unless `--include-e2e`).

When unavailable:

```bash
find . \( -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.spec.ts" -o -name "*.spec.tsx" \
  -o -name "test_*.py" -o -name "*_test.py" \) \
  ! -path "*/node_modules/*" ! -path "*/.next/*" ! -path "*/__pycache__/*" ! -path "*/e2e/*" | sort
```

If count exceeds 50 and `--deep` was not explicitly requested, auto-switch to `--quick`. Explicit `--deep` always takes precedence.

### 0.2 Pair with Production Files

For each test, identify its production counterpart:
- `__tests__/api/projects/[id]/route.test.ts` -> `app/api/projects/[id]/route.ts`
- `tests/unit/services/bar.test.ts` -> `lib/services/bar.ts`

If production file not found: flag as ORPHAN (test without source).

When CodeSift is available, use `search_symbols` or `find_references` for more reliable pairing in non-standard project layouts.

### 0.3 Pre-Batch Grouping

Before splitting into batches, group test files by production file. If multiple test files target the same production code (`foo.test.ts` + `foo.errors.test.ts`), they MUST go into the same batch so suite-aware Q7/Q11 scoring works correctly.

### 0.4 Golden File Calibration (recommended for first audit)

If this is the first audit of a project or agent scores seem inconsistent:
1. Pick 2-3 test files with known quality (one good, one bad, one mid)
2. Run a single calibration agent on those files
3. Compare scores to expectations. If drift >2 points, adjust prompt wording
4. Proceed with full evaluation

### 0.5 Batch Output Directory

```bash
mkdir -p zuvo/audits/.test-audit-batch
```

The orchestrator owns every file here: on the `model-run` route (Phase 1a) it writes each batch's
report through `model-run --out`; on the in-harness route (Phase 1b/1c) it saves each batch agent's
returned report through the 1d save gate. Cleaned up after the final report.

---

## Phase 1: Batch Evaluation

Phase 1 branches on the host (`env-compat.md` → Agent Dispatch). On a **Claude or Codex** host
every batch is audited by the routed cross-vendor reviewer — the other vendor's model, run as an
isolated CLI subprocess through `~/.zuvo/model-run` (1a) — with a labelled in-harness fallback for a
batch that route could not finish (1b). On **Cursor, Antigravity and Kimi** the in-harness Agent
dispatch is unchanged (1c). No auditor writes under `zuvo/audits/.test-audit-batch/` itself; every
file there is the orchestrator's.

**Agent Prompt (provided to each batch auditor):** the orchestrator passes the FENCED BODY ONLY from
`../../shared/includes/test-audit-batch-prompt.md` (loaded above under Mandatory File Loading) —
the text between that include's opening and closing ``` fences, never the `### Agent Prompt`
heading or the fences themselves. Before dispatch, the orchestrator substitutes BOTH placeholders:
`[BATCH FILE LIST]` with this batch's file list, and `[VERIFICATION CONTEXT]` with the value of the
route the batch runs on — `read-only reviewer, no shell` for a `model-run` subprocess (1a), `shell
available` for an in-harness Agent (1b, 1c).

### 1a. Claude and Codex hosts (`platform=claude` or `platform=codex`) — batches through `model-run`

Split grouped files into batches of 5 (a subprocess reviewer reads every file itself, and five keep
one batch inside its 480 s client budget), numbered 1..N. A Phase 0.3 group is never split: when
its paired test files do not fit into the current batch they move together into the next one, so a
batch holding one group of more than 5 files exceeds 5.

The shell of this route is one installed script, `~/.zuvo/test-audit-batch` (source:
`scripts/zuvo-home/test-audit-batch`), called once for the setup and once per group. Both calls are
single commands, valid as written in the harness's own shell — `bash`, or `zsh` (the Claude `Bash`
tool on macOS is `/bin/zsh`) — with no shell emulation to set up: the script runs under its own
`bash`. Never wrap a call in `bash -c`: that changes `$PPID`, which each call passes as `--owner`
and which is the run lock's owner. The script needs `perl` (present on macOS and Linux) to give each
batch its own process group.

**Setup — one Bash call before the first group.**

```bash
NBATCH=3   # the number of batches of this run
RUN_TOKEN= # empty for a new run; the run's token when this setup is re-run inside the same run
~/.zuvo/test-audit-batch setup --owner "$PPID" --nbatch "$NBATCH" --token "$RUN_TOKEN"
```

The call's contract:

- exit `0` — the lock is held and the prompts are written; the last stdout line is
  `RUN_TOKEN=<token>`: the orchestrator copies that value into the `RUN_TOKEN=` line of every group
  call of this run;
- exit `3` — `STOP:` on stderr with the reason (not an install root, a live foreign lock, a lock an
  earlier run of this session left, an undecidable owner, a contended lock, a `.lock` that is not a
  lock link (an older layout), a bad `NBATCH`, a prompt that could not be set aside);
  nothing of another run was touched;
- exit `1` — no git repository, or the batch directory cannot be made; exit `2` — a malformed call.

What the call does: it checks that `ZUVO_BASE` is an install root (an existing directory holding
`scripts/reviewer-model-route.sh`), takes the run lock `zuvo/audits/.test-audit-batch/.lock`, clears
this skill's batch files (no file of an earlier run may be read as this run's result; a re-run
inside the same run keeps its own, below), then writes and validates
`zuvo/audits/.test-audit-batch/batch-N.prompt` for every batch: the include's fenced body with the
`Verification context: [VERIFICATION CONTEXT]` field set to `read-only reviewer, no shell` and the
`[BATCH FILE LIST]` placeholder line removed. A prompt whose write fails, that comes out empty,
still carries either placeholder, or lacks the include's `OUTPUT LINE FORMAT` rule is set aside as
`batch-N.prompt.invalid` (with a `prompt-invalid:` line on stderr); the group call then records
`prompt-invalid` for that batch and it takes the fallback (1b). A prompt that cannot be set aside
(the move fails) would stay in place for a group call to run: the setup STOPs instead (exit 3),
naming it.

The lock is a symbolic link created with `ln -s`, which is atomic and fails when the name exists;
its target is the owner record `<pid> <epoch> <run token>`, so the lock and its owner appear in one
step. The pid is the harness process that runs the calls (`--owner "$PPID"`, the parent of each
call's shell — the same process for every call of one run). An owner counts as ALIVE when `ps`
shows that pid AND the process is older than the lock (a pid reused by a newer process is not the
owner) — `ps`, never `kill -0`, which fails with EPERM on another user's live process. A `ps` that
shows no process at all — not even the script's own shell (a sandbox, `hidepid`) — cannot tell a
gone owner from a live one: the setup then STOPs (exit 3) with the command that clears the lock,
never reclaims a lock whose owner may still be running. A live owner means another run
is using this checkout's batch directory: the setup prints `STOP:` and exits 3 without touching its
files. When that owner is THIS harness process under another run token, an earlier run of this
same session ended without releasing the lock: the `STOP:` line says so and names the command that
clears it. A lock whose owner is gone is stale: the setup takes the reclaim mutex
`zuvo/audits/.test-audit-batch/.lock.reclaim` (`mkdir`, atomic), re-reads the lock, moves it aside
to `.lock.stale.<token>` only if it is still the stale record it read, releases the mutex, and tries
again — so of two runs reclaiming at once exactly one wins. A reclaim mutex older than 120 s (its
mtime, read with GNU `stat -c %Y` or BSD `stat -f %m`) was left by a run that died inside the
reclaim: a setup removes it, once, and retries — no person has to. A setup re-run inside the SAME
run (its `RUN_TOKEN=` line set to the run's token, same harness process) keeps the lock AND the
results of batches 1..`NBATCH` already written (`batch-N.md`, `.rc`, `.status`, …): it rebuilds
only the prompts and drops the files of batches past `NBATCH`, so the orchestrator re-runs only
the groups whose batches are not DONE (a group call clears its own batches' results before it runs
them). A setup with a new token clears every batch file. Every
group call checks that the lock still names this harness process and this run token. On Codex the
owner pid is `$PPID` of the exec shell, which is unverified; if Codex runs each call under a fresh
parent, the group calls STOP on the foreign-owner check rather than run unprotected. The lock is
released with the batch directory in Phase 3; when a run STOPs for any other reason than a live
foreign lock, the orchestrator releases it with
`~/.zuvo/test-audit-batch release --owner "$PPID" --token <RUN_TOKEN>` (exit 0 released, 3 the lock
is another run's and was left alone).

**Then the orchestrator writes `zuvo/audits/.test-audit-batch/batch-N.files`** for every batch —
one line per test file, two TAB-separated fields: `<absolute test path>` TAB
`<absolute production path, or ORPHAN>`. Absolute paths, because the client runs in a neutral
directory, not in the repository. A path holding a TAB or a newline cannot be listed: the group
call refuses a listing whose every line is not exactly two fields — field 1 an absolute path, field
2 an absolute path or `ORPHAN` — records `listing-invalid` for that batch with a `listing-invalid:`
line on stderr, and never runs it. Field 1 is the test path, and the report heading for that file is
`### ` followed by field 1 exactly — the heading the DONE gate below looks for. The group call
renders `batch-N.list` from it for the reviewer (`<test path> (production: <production path>)`,
one line per file), and `model-run` concatenates `--prompt-file` and `--append-file` byte for byte,
in order: the fenced body ends with `Files to audit:` followed by the placeholder, so the listing
lands exactly where the placeholder stood.

**Groups:** `P` batches at a time — `${ZUVO_TEST_AUDIT_PARALLEL:-2}`, default 2, read as a decimal
number with leading zeros stripped (`05` is 5); a value that is empty, not a whole number, or below
1 falls back to 2, and anything above 4 — including any number of more than three digits, which is
never evaluated — is capped at 4. Issue **ONE Bash call
per GROUP**, each with `timeout: 600000` (the Claude `Bash` tool; on Codex, `exec_command` with
`timeout_ms: 600000`): the call starts at most `P` background `model-run` jobs, waits for them, and
runs the DONE gate. Its batches run side by side, so the call lasts one 480 s client budget plus
start-up. Never put a second group into the same call — two 480 s batches back to back overrun
the 600 s ceiling and the harness kills the call. The call's own wait is bounded at `BOUND=560` s,
inside that ceiling. Each batch's `model-run` runs in its own process group (perl `setpgrp`, then
`exec`, its pid recorded in `batch-N.pgid`); a batch still running at `BOUND` has that group
terminated — TERM, then KILL after `GRACE=25` s, which covers the 22 s `model-run` may take to stop
its client and remove its temp files after a TERM — and once reaped it is marked `timeout-orphan` in
`batch-N.orphan`, unless its `batch-N.rc` already holds one of model-run's own exits (it finished as
the bound expired, and that exit stands). `BOUND` + `GRACE` is 585 s, 15 s inside the ceiling. No
writer of this group outlives the call. `NBATCH` and `FIRST` must be positive whole numbers with
`FIRST` no larger than `NBATCH`, or the call STOPs. The first call has `FIRST=1`; the call's last
line is `NEXT_FIRST=<n>` — the next call's `FIRST`, copied as printed (it is this call's last batch
plus one, so `P` is never recomputed) — or `NEXT_FIRST=none` after the group holding batch `NBATCH`.
A call that exits 2 after a `STOP:` line ends the run (see the table).

```bash
NBATCH=3   # the number of batches of this run
FIRST=1    # this group's first batch: 1, then the NEXT_FIRST= the previous call printed - each group is its own call
RUN_TOKEN= # the RUN_TOKEN= value the setup call printed
~/.zuvo/test-audit-batch group --owner "$PPID" --nbatch "$NBATCH" --first "$FIRST" --token "$RUN_TOKEN"
```

The call's contract:

- exit `0` — stdout holds one `batch-N DONE rc=<rc> <status line>` or `batch-N FAILED rc=<rc> <status line>`
  per batch of the group, then `NEXT_FIRST=<n>` or `NEXT_FIRST=none`;
- exit `2` — a batch ended with model-run's usage error: `STOP:` and that batch's `batch-N.status`
  on stdout; the run ends;
- exit `3` — `STOP:` on stderr before anything ran: a bad `NBATCH` or `FIRST`, no `perl`, or this
  run does not hold the lock;
- exit `1` — no git repository.

Each batch is run as `model-run --route --mode audit --access read` with the repository root as
`--read-root`, the batch's prompt and rendered listing, `--timeout 480`, `--out` on `batch-N.md`,
and the script's own `--require` / `--reject` patterns. `--require` accepts an answer with a real
`Tier: A|B|C|D` line, a `Tier: INCOMPLETE` line (a file with nothing applicable) or an AUTO TIER-D
red-flag line (a batch may be ALL AUTO TIER-D files, which have no `Tier:` line); `--reject` refuses
any answer carrying either template line of the prompt verbatim — an echo of the prompt, not an audit.
`model-run --route` runs only a genuine cross-vendor reviewer (`routing_status=ok`); any other route
exits 1 without running anything, and `--out` is written only on exit 0. `batch-N.status` may hold
`model-run: note: …` lines; the status is the line starting `model-run: status=` (always the last).

**DONE gate.** A batch is DONE only when its `batch-N.rc` is `0` AND `batch-N.files` lists at least
one test path AND, for EVERY listed path, `batch-N.md` has the heading `### <field 1>` and, inside
that section, a column-0 `Tier: <A|B|C|D>` line, a `Tier: INCOMPLETE` line, or a
`Red flags: … -> AUTO TIER-D` line. A heading and a listed path are compared after the same
normalisation on both sides — outer blanks removed, one pair of wrapping backticks removed, a leading
`./` removed — so `` ### `<path>` `` still names its file; any other difference does not. A section
runs to the next heading that is another LISTED path: a `### ` line of the reviewer's own inside a
section (`### Notes`) does not end it, while a `### ` heading that is one path-shaped word (no blank,
a `/` in it) and is not listed does — a verdict under some other file's heading never counts for the
listed file above it. Each listed path is judged on its own section only. Every other outcome is a
failed batch; the call quarantines its `batch-N.md`, if any, as `batch-N.md.incomplete` (outside
Phase 2's `batch-*.md` glob) and prints `FAILED`:

| `batch-N.rc` | Meaning | Action |
|---|---|---|
| `0`, gate passes | a usable audit of every listed file | DONE |
| `0`, gate fails | a file's section or verdict line is missing, or the listing is empty | quarantine, fallback (1b) |
| `1` | unavailable — route not ok, CLI missing or too old | fallback (1b) |
| `2` | usage — the command itself is malformed | STOP: the call prints `STOP:` and `batch-N.status` and exits 2; the run ends here — it would fail the same way for every batch, and a fallback would hide it |
| `3` | no usable answer — empty, auth, `--require` miss, `--reject` hit | fallback (1b) |
| `4` | the client ran and failed | fallback (1b) |
| `124` | timeout | fallback (1b) |
| `timeout-orphan` | still running at the call's `BOUND`; its process group was killed | fallback (1b) |
| `prompt-invalid` | the setup could not build a valid prompt | fallback (1b) |
| `listing-invalid` | `batch-N.files` is missing, empty, or not two TAB fields of absolute paths per line | fallback (1b) |
| `no-rc` | the job died before recording an exit — never a success | fallback (1b) |

Do not re-run `model-run` for a failed batch: a non-ok route stays non-ok, and a retry is not a
fallback.

**Header line.** For every batch the orchestrator records one line, and the Phase 2 report carries
them in its header, right under `Verification:`:
`Batch auditor: <client>/<model> route=<lane> status=<status> batch=<N>` — on this route taken from
the batch's `model-run: status=` line (e.g. `Batch auditor: codex/gpt-6-sol route=cross-vendor status=ok batch=1`),
from 1b's labels on a fallback, or `status=INCOMPLETE` for a batch neither produced.

### 1b. Fallback for a failed batch — in-harness Agent, labelled degraded

A batch 1a could not finish is re-dispatched ONCE as an in-harness Agent whose model comes from the
router, never from this file: run `$ZUVO_BASE/scripts/reviewer-model-route.sh --fallback` (no
override flags, a 5 s timeout, the six-key parser rules of `test-reviewer-routing.md` → Reviewer-model
resolution). `routing_status=routing-failed`, or an answer that fails the parser → no agent, the batch
is INCOMPLETE. Otherwise dispatch with `model:` set to its `reviewer_model` and label the batch
`route=<reviewer_lane>` with `status=in-family-fallback (degraded)` for `in-family-fallback`,
`status=in-family-fallback (degraded, writer unknown)` for `unknown-writer-model`, and
`status=in-family-fallback (degraded, same model)` for `same-model-fallback`. A fallback batch is
never reported as cross-vendor or as `status=ok`. Its header line is
`Batch auditor: <client>/<reviewer_model> route=<reviewer_lane> status=<label> batch=<N>`, where
`<client>` is the harness that ran the in-harness agent (`claude` or `codex`).

```
Agent: Test Quality Auditor — fallback (per failed batch)
  model: <reviewer_model from reviewer-model-route.sh --fallback>
  type: "general-purpose"  # read-only: no Edit/Write; may run read-only verification commands (tests, lint) — never modifies the repo (Explore lacks mcp__codesift__*)
  instructions: the fenced-body prompt, [VERIFICATION CONTEXT] = shell available, [BATCH FILE LIST] = batch-N.files rendered one line per file as "<test path> (production: <production path>)"
  input: batch file list with paired production files, CODESIFT_AVAILABLE
```

On a Codex host the fallback is a Codex sub-agent with that `reviewer_model`. Where the host cannot
dispatch one (`env-compat.md` → Codex: record unavailable dispatch as a degradation), the
orchestrator audits the batch inline and labels it `route=same-model-fallback status=in-family-fallback (degraded, same model)`.

The returned report goes through the 1d save gate. A fallback that fails too — no agent, a dispatch
error, or a return missing a file's section or verdict line — leaves the batch INCOMPLETE: no batch file, a
`status=INCOMPLETE` header line, and Phase 2's incomplete-batch rule (step 4 logs the gap, step 5
counts it INCOMPLETE).

### 1c. Cursor, Antigravity and Kimi hosts — in-harness Agent (unchanged)

Split grouped files into batches of 8-10. For each batch, spawn a Task agent or process inline.

Each Task agent dispatch:
```
Agent: Test Quality Auditor (per batch)
  model: "sonnet"
  type: "general-purpose"  # read-only: no Edit/Write; may run read-only verification commands (tests, lint) — never modifies the repo (Explore lacks mcp__codesift__*)
  instructions: evaluate test files against Q1-Q25 and AP anti-patterns (see the Agent Prompt in `../../shared/includes/test-audit-batch-prompt.md`)
  input: batch file list with paired production files, CODESIFT_AVAILABLE
```

This path substitutes `[VERIFICATION CONTEXT]` with `shell available` and `[BATCH FILE LIST]` with
the batch's file list. Its header line is `Batch auditor: <host>/<model> route=in-harness status=in-harness batch=<N>`
(`status=INCOMPLETE` for a batch the 1d gate did not save).

### 1d. Saving an in-harness report (1b, 1c)

The batch agent returns its report as its final message. The orchestrator saves that returned
report to `zuvo/audits/.test-audit-batch/batch-{N}.md` only if, for every test file in the batch,
it contains a `### [filename]` section (the include's own FULL/SHORT format heading, path as listed
in the batch) AND, inside that section, a column-0 `Tier: <A|B|C|D>` line, a `Tier: INCOMPLETE`
line, or a `Red flags: … -> AUTO TIER-D` line; a return missing any file's section or verdict line
is not saved, and that batch then counts as a missing batch file under
Phase 2's incomplete-batch rule (step 4 logs the gap, step 5 counts it INCOMPLETE). This is the
per-file check of 1a's DONE gate, run by the same code — headings compared after the same
normalisation, sections ended the same way:

```bash
N=1   # the batch
~/.zuvo/test-audit-batch save --batch "$N"
```

Before the call the orchestrator writes two files under `zuvo/audits/.test-audit-batch/`:
`batch-N.files`, one line per test file of the batch — `<test path as listed to the agent>` TAB
`<production path, or ORPHAN>` (1b already has it from 1a) — and `batch-N.returned`, the agent's
report exactly as returned. Exit 0 prints `batch-N SAVED`: the report is now `batch-N.md`. Exit 1
prints `batch-N NOT-SAVED: <why>`: the report was moved to `batch-N.md.incomplete`, outside Phase 2's
glob, and the batch is INCOMPLETE. The orchestrator never writes `batch-N.md` itself: any other
outcome of the call — the script missing (exit 127: `./scripts/install.sh` was not run on this
machine), a usage error (exit 2) — also leaves the batch INCOMPLETE, never saved unchecked.

---

## Phase 2: Aggregate Results

Read all batch files from `zuvo/audits/.test-audit-batch/`:

1. Glob for `zuvo/audits/.test-audit-batch/batch-*.md`
2. Parse summary tables for tier counts
3. Parse per-file blocks for detailed analysis
4. If any batch file is missing (agent failure), log the gap
5. Count INCOMPLETE files separately — every file whose tier line is `Tier: INCOMPLETE` (nothing applicable to score), and every file of a batch that has no batch file; exclude them from numeric tier averages and passing totals, and keep the overall audit INCOMPLETE until their evaluation is resolved

Build the summary report:

```markdown
# Test Quality Audit Report

Date: [date]
Project: [name]
Files audited: [N]
Total tests: [count from test runner]
Checkout: [absolute branch/worktree path]
Tree: [branch, commit, dirty-tree identity if applicable]
Verification: [commands + cwd + run IDs/artifacts + exit/result summaries; skips and unrun checks]
Batch auditor: [one line per batch, as Phase 1 records it: <client>/<model> route=<lane> status=<status> batch=<N>]
Evidence map: [per production file/symbol → test branch citations → matching coverage/mutation artifact scope]

## Summary by Tier

| Tier | Count | % | Action |
|------|-------|---|--------|
| A (>=82% of applicable) | [N] | [%] | No action |
| B (>= 53% and < 82% of applicable) | [N] | [%] | Fix gaps |
| C (<53% of applicable OR any critical gate = 0) | [N] | [%] | Major rewrite |
| D (auto Tier-D red flag) | [N] | [%] | Delete + rewrite |
| INCOMPLETE (no tier) | [N] | [%] | Finish missing evaluation |
| ORPHAN | [N] | [%] | Verify or delete |

## Critical Gate Failures

| File | Score | Failed Qs | Top Gap |
|------|-------|-----------|---------|

## Red Flag Summary (Auto Tier-D)

| File | Red Flag | Details |
|------|----------|---------|

## Untested Public Methods

| File | Untested Methods | Impact |
|------|-----------------|--------|

## Top Failed Questions (across all files)

| Question | Fail count | % of files | Pattern |
|----------|-----------|------------|---------|

## Anti-pattern Hot Spots

| Anti-pattern | Files affected | Instances |
|-------------|---------------|-----------|

## Tier D -- Rewrite Queue
## Tier C -- Major Fix Queue
## Tier B -- Targeted Fix Queue
## Tier A -- No Action
```

Save to: `zuvo/audits/test-quality-audit-[date].md` — at the **project root** (`zuvo/` resolves via `git rev-parse --show-toplevel`; override `$ZUVO_OUTPUT_DIR`. See `../../shared/includes/report-output-location.md`).
If `--details` flag: also save per-file reports to `zuvo/audits/test-audit-details/`

## Phase 3: Cleanup Batch Files

```bash
rm -rf zuvo/audits/.test-audit-batch
```

## Phase 3b: Adversarial Review on Audit Report (MANDATORY — do NOT skip)

After the audit report is generated, run cross-model validation to catch Q-score inflation and coverage theater. Runs on ALL audits (not just --deep).

```bash
~/.zuvo/adversarial-review --mode tests --files "zuvo/audits/test-quality-audit-[date].md"
```

If `adversarial-review` is not in PATH: `~/.zuvo/adversarial-review` (stable; the versioned cache path breaks after any release)

Wait for complete output. Verify each actionable finding against the actual source/test branches
and artifact scope before changing scores. Record rejected false positives with source evidence;
severity alone does not establish validity. Then, for confirmed findings:
- **CRITICAL** (passing Q-score contradicted by evidence) → fix in report before delivery
- **WARNING** (coverage theater not flagged) → correct affected evidence, scores and tier; record unresolved gaps explicitly
- **INFO** → ignore

Apply validated corrections to the audit report, including per-file scores, aggregate counts and
evidence attribution, before delivery. Do not start a recursive review loop of report corrections
unless the user requested one. The existing mandatory review is one bounded review of the report;
record its findings and dispositions. Link the actual branch/worktree files so reviewers can open
the source that was audited.

## Phase 4: Coverage Registry Update

Under `--read-only`: skip Phases 4-6 entirely and present the report (Phase 7 fix workflow is also off).

Read `memory/coverage.md`. If it does not exist, create it now.

For each audited test file, find its production file row in coverage.md:

| Audit Tier | Coverage Status | Rationale |
|-----------|----------------|-----------|
| A (>=82% of applicable, critical gates PASS) | COVERED | Tests are solid |
| B (>=53% and <82% of applicable, critical gates PASS) | PARTIAL-QUALITY | Has tests but quality issues |
| C (<53% of applicable OR any critical gate = 0) | PARTIAL-QUALITY | Major quality gaps |
| D (auto Tier-D red flag) | PARTIAL | Effectively untested |
| INCOMPLETE (no tier) | Leave existing row unchanged | Evaluation unavailable; never register as COVERED |

Only downgrade coverage status, never upgrade. If production file is not yet in coverage.md, add it.

Output: `COVERAGE UPDATE: [N] rows updated ([N] downgraded, [N] confirmed, [N] new)`

## Phase 5: Backlog Persistence

Persist findings to `memory/backlog.md`:

1. Read `memory/backlog.md`. If missing, create with template.
2. Fingerprint each finding: `file|Q/AP-id|signature`. Dedup: existing = increment `Seen`.
3. Delete resolved items.

Full protocol: `../../shared/includes/backlog-protocol.md`.

**What to persist:**
- **Tier C/D files:** all findings. Source: `test-audit/{date}`. Category: Test.
- **Tier B critical gate failures** (Q7/Q11/Q13/Q15/Q17=0): separate item per gate
- **Auto Tier-D red flags** (AP13/AP14/AP16): always persist as HIGH

## Phase 6: Persistence Verification

Before presenting the report, verify all writes completed:

```
PERSISTENCE VERIFICATION
  coverage.md updated: [N] rows ([N] downgraded, [N] confirmed, [N] new)
  backlog.md updated:  [N] entries ([N] new, [N] deduped)
  batch files cleaned: [yes/no]
```

If any step is incomplete, go back and finish it before continuing.

## Phase 7: Post-Audit Fix Workflow

After presenting the report, the user may request fixes:

1. **Fix** -- rewrite test files following the quality rules
2. **Test** -- run the test suite to confirm all tests pass
3. **Verify** -- for each fixed file:
   - Only test files modified (no production code changes)
   - Full test suite green
   - All modified test files <= 400 lines
   - Q1-Q25 self-eval on each fixed file
   - Tier improvement confirmed (D->C+, C->B+, B->A)
4. **Commit** -- behavior per `--commit` flag (ask/auto/off)
5. **Re-audit** -- optionally re-run on fixed files to verify improvement

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| Tier D files (any AUTO TIER-D red flag, or a critical Q gate = 0) | Rewrite tests | `zuvo:write-tests [path]` |
| Same AP across 10+ files | Batch fix | `zuvo:fix-tests --pattern [AP-ID]` |
| Tier B-C with Q7=0 | Add error tests | `zuvo:write-tests [path]` |
| Coverage gaps (methods untested) | Write missing tests | `zuvo:write-tests [path]` |
| Test infra issues (runner config) | Optimize runner | `zuvo:tests-performance` |

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Red flag pre-scan ran on every batch
[ ] Phantom mock detection ran: unused mocks listed
[ ] Untested public methods listed per file
[ ] Adversarial review ran on audit report
[ ] Coverage registry updated: memory/coverage.md rows written
[ ] Backlog updated for critical gate failures
[ ] Report saved to zuvo/audits/
[ ] Run: line printed and appended to log
```

## TEST AUDIT COMPLETE

### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  triggers_held: language=<X> framework=<X> test_runner=<X>
  required_tool_calls:
    find_dead_code: [<N> orphan helpers | NOT_CALLED — VIOLATES_TRIGGER]
    find_clones: [<N> dup tests | NOT_CALLED — VIOLATES_TRIGGER]
    find_references: [<N> ref-checks | NOT_CALLED — VIOLATES_TRIGGER]
    search_patterns: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    audit_scan: [<N> findings | NOT_CALLED — VIOLATES_TRIGGER]
    scan_secrets: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    stack_specific: [<result> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED]
    verify_audit_pass: [yes(<verified>/<total>) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL — <which gates missing>]
```

If `gate_status = FAIL` → VERDICT = INCOMPLETE.

Append the Run line via the retro-gated wrapper (NOT direct `>> runs.log`):

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Run: <ISO-8601-Z>\ttest-audit\t<project>\t<N-critical>\t<N-total>\t<VERDICT>\t-\t<N>-dimensions\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).

---

## Execution Notes

- Batch auditors, QUICK and DEEP alike: on Claude and Codex hosts the routed cross-vendor reviewer through
  `model-run` (Phase 1a), batches of 5 in groups of `${ZUVO_TEST_AUDIT_PARALLEL:-2}`, one Bash call per group;
  a failed batch falls back to an in-harness Agent labelled `in-family-fallback (degraded)` (Phase 1b)
- Cursor and Antigravity process in-harness batches sequentially; Kimi dispatches its sub-agents (Phase 1c)
- Run the project's test suite first to confirm baseline passes. Auto-detect runner from config files.
- Estimated durations, 50 files: in-harness (1c) QUICK ~2 min, DEEP ~10 min. On the `model-run` route
  (1a) 50 files are 10 batches = 5 groups at the default `P=2`; one measured batch took 40-72 s, so
  ~4-6 min typical, and the ceiling is 5 groups × (560 + 25) s = 2925 s ≈ 49 min: a group call lasts at
  most its `BOUND` plus the `GRACE` before the KILL, not one 480 s client budget
