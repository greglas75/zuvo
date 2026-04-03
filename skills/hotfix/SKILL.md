---
name: hotfix
description: "Fast-track production bug fix pipeline. Minimum ceremony, maximum safety for critical production issues affecting 1-3 files. Creates hotfix branch, locates root cause, applies minimal fix with regression test, and offers cherry-pick or PR. Flags: --from [branch], --deploy, --no-test."
---

# zuvo:hotfix — Fast-Track Production Fix

A streamlined pipeline for when production is broken and speed matters. Trades ceremony for velocity while preserving the safety gates that prevent a bad fix from making things worse. Designed for fixes that touch 1-3 production files — anything larger needs `zuvo:debug` for investigation or `zuvo:build` for implementation.

**Scope:** Critical production bugs requiring an immediate, targeted fix. 1-3 production files maximum. Test files and run-log do not count toward the file limit.
**Out of scope:** Feature work (`zuvo:build`), investigation without a known fix path (`zuvo:debug`), refactoring (`zuvo:refactor`), non-critical bugs that can wait for a normal release cycle (`zuvo:ship`).

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `--from [branch]` | Base branch for the hotfix (default: auto-detect main/master) |
| `--deploy` | After merge, suggest running `zuvo:deploy` |
| `--no-test` | Skip full test suite, run only affected tests (true emergencies only) |
| _(remaining text)_ | The bug description, error message, Sentry link, or reproduction steps |

Flags can be combined: `zuvo:hotfix payment null crash --from release/2.1 --deploy`

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

**Interaction behavior is governed entirely by env-compat.md.** This skill does not override env-compat defaults. Specifically:
- Commit confirmation follows env-compat rules for the detected environment.
- Cherry-pick and PR creation require explicit user confirmation in interactive environments. In non-interactive environments: skip remote operations and print manual commands.

---

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Key tools for hotfix:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 1 | Trace callers of buggy function | `trace_call_chain(repo, symbol_name, direction="callers", depth=2)` | Grep for function name |
| 1 | Understand buggy function in context | `get_context_bundle(repo, symbol_name)` | Read the entire file |
| 1 | Find where an error is thrown | `search_text(repo, query="error message", regex=true)` | Grep |
| 1 | Recent changes near the bug | `changed_symbols(repo, since="HEAD~5")` | `git log --oneline -5 -- [file]` |
| 2 | Check blast radius of fix | `impact_analysis(repo, since="HEAD", depth=1)` | Grep for imports of changed files |

After editing any file, update the index: `index_file(path="/absolute/path/to/file")`

---

## Mandatory File Reading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-patterns.md           -- READ/MISSING
  2. {plugin_root}/rules/cq-checklist.md           -- READ/MISSING
  3. {plugin_root}/shared/includes/auto-docs.md    -- READ/MISSING
  4. {plugin_root}/shared/includes/session-memory.md -- READ/MISSING
```

Where `{plugin_root}` is resolved per `env-compat.md`.

**Deferred loading:**
- `{plugin_root}/rules/testing.md` — read before writing regression test (Phase 2.2)

**If any CORE file missing:** Proceed in degraded mode. Note in Phase 3 output.

---

## Phase 0: Triage

Speed is critical. This phase should take under 30 seconds.

1. **Parse input.** Extract the bug description from `$ARGUMENTS`. Accept any of:
   - Error message or stack trace
   - Sentry/Datadog/PagerDuty link or alert text
   - Plain description ("payments returning null for discounted orders")

2. **Detect base branch.** If `--from` was passed, use that branch. Otherwise auto-detect:
   ```bash
   BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
     | sed 's@^refs/remotes/origin/@@' || echo main)
   ```
   Fallback: check for `main`, then `master`.

3. **Create hotfix branch:**
   ```bash
   SLUG=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | head -c 40)
   BRANCH="hotfix/$(date +%Y-%m-%d)-${SLUG}"
   git checkout -b "$BRANCH" "origin/$BASE_BRANCH"
   ```

4. **Read project context.** Quick scan only — not a full discovery pass:
   - Read `CLAUDE.md` for conventions
   - Detect test runner from config files (`package.json`, `pyproject.toml`, `Cargo.toml`, etc.)
   - Read `memory/project-state.md` if it exists (recent activity may provide context)

Output:
```
HOTFIX TRIAGE
  Bug:         [1-line description]
  Base:        [base branch]
  Branch:      hotfix/YYYY-MM-DD-slug
  Test runner: [detected runner]
```

---

## Phase 1: Locate & Understand

Find the bug fast. Target: root cause identified in under 2 minutes. Do not explore broadly — go straight to the failure point.

### 1.1 Locate the Failure Point

Use the input to find the affected code:

- **If stack trace provided:** Read the file and line directly. The root cause is usually earlier in the chain, not the last frame.
- **If error message provided:** Search codebase for the error string. Use `search_text(repo, query="error message")` or Grep.
- **If Sentry/monitoring link:** Extract the error class, message, and stack from the alert. Treat as stack trace.
- **If behavioral description:** Identify the affected feature or endpoint. Read the entry point, trace to the likely failure point.
- **If recent regression suspected:** `changed_symbols(repo, since="HEAD~10")` — cross-reference recent changes with the error location.

### 1.2 Read the Affected Code

Read the full function or method containing the bug. Read immediate callers (1-2 levels up) if needed for context. If CodeSift is available, use `get_context_bundle(repo, symbol_name)` to get the function with its imports and neighbors.

### 1.3 Identify Root Cause

Determine the specific line, condition, or assumption that fails. Distinguish root cause from symptoms.

Print:
```
ROOT CAUSE: [one line — e.g., "PaymentService.process() — null check missing on discount field"]
AFFECTED FILES: [list of production files that need changes]
```

### 1.4 Scope Guard

Count the production files that need changes:

- **1-3 files:** Proceed to Phase 2.
- **>3 files:** STOP. Print:
  ```
  SCOPE EXCEEDED: [N] production files identified. Hotfix is designed for 1-3 files.
  Recommendation: use zuvo:debug for investigation, then zuvo:build for the fix.
  ```
  Ask the user to confirm override or switch skills. Do not proceed silently.

---

## Phase 2: Fix

### 2.1 Write the Minimal Fix

Apply the smallest possible change that resolves the root cause.

Rules:
- Touch only the files identified in Phase 1. No opportunistic cleanup.
- Follow project conventions from CLAUDE.md and rules directory.
- Add a code comment if the fix is non-obvious (e.g., `// hotfix: guard against null discount — see [ticket/link]`).
- Prefer defensive fixes (null checks, guards, fallbacks) over structural changes.
- Do not refactor surrounding code. Do not "improve" nearby logic. One surgical fix.

### 2.2 Write Regression Test

Read `{plugin_root}/rules/testing.md` before writing the test.

Write a targeted test that:
1. Recreates the exact condition that triggered the bug
2. Asserts the correct behavior (the bug no longer occurs)
3. Would have caught this bug if it had existed before the original code was written

The regression test should be minimal — test ONLY the bug, not surrounding code. Name it descriptively:
- `[module].hotfix.test.{ext}` or
- `[module].regression.[slug].test.{ext}`

### 2.3 Run Tests

**If `--no-test` is NOT set (default):**
1. Run the regression test to confirm it passes
2. Run the full test suite
3. If any pre-existing tests fail: investigate — the fix may have side effects. Fix before proceeding.

**If `--no-test` IS set:**
1. Run ONLY the regression test and tests in the same file/module as the fix
2. Print warning: `[--no-test] Full suite skipped. Run full tests before merging.`

### 2.4 CQ Self-Evaluation (Abbreviated)

Hotfix uses an abbreviated CQ check — only the safety-critical gates that matter most for emergency fixes. Read `{plugin_root}/rules/cq-checklist.md` for full gate definitions.

Run these gates on changed production files only:

| Gate | Name | Why it matters for hotfix |
|------|------|--------------------------|
| CQ3 | Boundary Validation | Hotfixes often add guards — verify they are complete |
| CQ5 | Error Propagation | Fix must not swallow errors or change error contracts |
| CQ8 | Infrastructure Errors | If fix touches I/O, timeout handling must be present |
| CQ10 | Security Boundaries | Hotfix must not weaken auth, authz, or data access |
| CQ14 | No Duplicated Logic | Fix should not copy-paste existing logic |

Score each gate (1 = satisfied, 0 = violated, N/A = not applicable). Provide file:function:line evidence for each gate scored as 1.

**Any gate = 0:** Fix before proceeding. A hotfix that introduces a new vulnerability or error-handling gap is worse than the original bug.

---

## Phase 3: Verify & Ship

### 3.1 Final Verification

1. Run the regression test one more time (fresh run, not cached results)
2. Confirm all tests pass (or affected tests pass if `--no-test`)
3. Read `{plugin_root}/shared/includes/verification-protocol.md` — no completion claims without fresh evidence

### 3.2 Stage and Commit

Stage exactly the files created or modified:
```bash
git add [explicit file list — never -A or .]
```

Commit with a conventional `fix:` message:
```bash
git commit -m "fix: [concise description of what was fixed]"
```

Follow env-compat interaction rules for commit confirmation.

### 3.3 Diff Summary

Print a summary of the change:
```
DIFF SUMMARY
  Files changed:  [N] production, [N] test
  Lines added:    [N]
  Lines removed:  [N]
```

### 3.4 Next Steps

Offer the user options based on context:

**Interactive environments:**
- "Cherry-pick to [base branch]?" — if on a hotfix branch and user wants to merge directly
- "Create PR targeting [base branch]?" — if the team uses PR workflow
- "Push branch?" — if the user wants to push for CI before merging

**Non-interactive environments:**
Print the manual commands:
```
[NON-INTERACTIVE] Remote operations skipped. Run manually:
  git push origin hotfix/YYYY-MM-DD-slug
  gh pr create --base [base-branch] --title "fix: [description]"
```

**If `--deploy` was passed:**
After merge confirmation, print:
```
Deploy flag set. Next: zuvo:deploy
```

---

## Completion

```
HOTFIX COMPLETE
----------------------------------------------------
Branch:     hotfix/YYYY-MM-DD-slug
Root cause: [1-line root cause explanation]
Fix:        [file:line — brief description of change]
Test:       [test file path]
Files:      [N] production, [N] test
CQ (critical): CQ3[✓/✗] CQ5[✓/✗] CQ8[✓/✗] CQ10[✓/✗] CQ14[✓/✗]
Tests:      [PASS — N tests | PARTIAL — affected only (--no-test)]
Status:     [ready to cherry-pick / PR created / committed]

Next steps:
  zuvo:review [fixed-files]  — independent review (recommended)
  zuvo:deploy                — deploy when merged (if --deploy)
----------------------------------------------------
```

---

## Auto-Docs

After printing the HOTFIX COMPLETE block, update project documentation per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the hotfix — bug description, root cause, fix applied, files changed, CQ gate results.
- **api-changelog.md**: Update if the fix changed any API endpoint behavior or error responses.

Use context from the hotfix phases — do not re-read source files. If auto-docs fails, log a warning and proceed to Session Memory.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with hotfix description, root cause, CQ gate results, verdict.
- **Active Work**: Update current branch and hotfix status.
- **Backlog Summary**: No backlog changes expected (hotfix does not investigate unrelated issues).

If `memory/project-state.md` doesn't exist, create it (full Tech Stack detection + all sections).

---

## Run Log

Append one TSV line to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`. All fields are mandatory:

| Field | Value |
|-------|-------|
| DATE | ISO 8601 timestamp |
| SKILL | `hotfix` |
| PROJECT | Project directory basename (from `pwd`) |
| CQ_SCORE | `critical-only` (abbreviated CQ — 5 gates) |
| Q_SCORE | `-` (no formal Q self-eval on hotfix regression test) |
| VERDICT | PASS / FAIL from Phase 3.1 verification |
| TASKS | Number of production files fixed |
| DURATION | `hotfix` |
| NOTES | `[HOTFIX] root-cause-summary` (max 80 chars) |

---

## Flag Reference

| Flag | Effect |
|------|--------|
| `--from [branch]` | Base branch for hotfix (default: auto-detect main/master) |
| `--deploy` | Suggest `zuvo:deploy` after merge |
| `--no-test` | Run only affected tests, skip full suite |

Flags are additive. All CQ safety gates run regardless of flags.
