---
name: hotfix
description: "Fast-track production bug fix pipeline. Minimal ceremony, maximum safety: triage, locate root cause, apply smallest fix, regression test, cherry-pick or PR. Scope limited to 1-3 files. Flags: --from [branch], --deploy, --no-test."
---

# zuvo:hotfix — Fast-Track Production Fix

Emergency fix pipeline for production bugs. Speed with safety: find root cause, apply the smallest possible change, verify with targeted tests, and ship.

**Scope:** Critical production bugs requiring immediate fix. Maximum 3 production files.
**Out of scope:** Investigation without known fix (`zuvo:debug`), feature work (`zuvo:build`), refactoring (`zuvo:refactor`), post-mortem analysis (`zuvo:incident`).

## Argument Parsing

Parse `$ARGUMENTS`:

| Flag | Effect |
|------|--------|
| _(text)_ | Bug description, error message, or Sentry link |
| `--from [branch]` | Base branch (default: auto-detect main/master) |
| `--deploy` | After merge, suggest running `zuvo:deploy` |
| `--no-test` | Run only affected tests, skip full suite (true emergencies) |

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Hotfix-specific CodeSift usage:**
- `trace_call_chain(repo, symbol_name, direction="up", depth=3)` — find callers of broken function
- `get_context_bundle(repo, symbol_name)` — understand broken function with imports
- `changed_symbols(repo, since="HEAD~5")` — recent changes that may have caused the bug
- `impact_analysis(repo, since="HEAD~1", depth=2)` — blast radius of the fix

## Mandatory File Reading

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-patterns.md           -- READ/MISSING
  2. {plugin_root}/rules/cq-checklist.md           -- READ/MISSING (critical gates only)
  3. {plugin_root}/shared/includes/auto-docs.md    -- READ/MISSING
  4. {plugin_root}/shared/includes/session-memory.md -- READ/MISSING
```

---

## Phase 0: Triage

1. Parse the bug description / error message / Sentry link
2. Detect base branch:
   ```bash
   git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'
   ```
   Fallback: check for `main`, then `master`.
3. Create hotfix branch:
   ```bash
   git checkout -b hotfix/YYYY-MM-DD-slug [base-branch]
   ```
4. If `--from` specified, branch from that instead

Print:
```
TRIAGE
  Bug:      [one-line description]
  Branch:   hotfix/YYYY-MM-DD-slug (from main)
  Severity: [inferred: CRITICAL/HIGH based on description]
```

---

## Phase 1: Locate Root Cause

**Time-box: find root cause quickly. Do not explore broadly.**

1. If error message / stack trace provided:
   - Search for the error: `search_text(repo, query="error message")` or Grep
   - Read the throwing function + its callers (1-2 levels up)

2. If behavioral description:
   - Identify the affected feature / endpoint
   - Read the entry point, trace to the likely failure point

3. If recent regression suspected:
   - `changed_symbols(repo, since="HEAD~10")` — what changed recently?
   - Cross-reference with error location

4. Confirm root cause. Print:
```
ROOT CAUSE
  Location:  src/services/payment.ts:142
  Function:  PaymentService.processDiscount()
  Problem:   Null check missing — discount field undefined for non-discounted orders
  Introduced: commit abc123 (2026-04-02, "Add discount calculation")
```

5. Count affected files. **If >3 production files needed: STOP.**
   - Recommend `zuvo:debug` for investigation or `zuvo:build` for broader fix.

---

## Phase 2: Fix

### 2.1: Apply Minimal Fix

Write the **smallest possible change** that fixes the bug. Do not refactor surrounding code. Do not "improve" nearby logic. One surgical fix.

### 2.2: Write Regression Test

Write ONE targeted test that:
- Reproduces the exact bug scenario (would fail without the fix)
- Verifies the fix works
- Names clearly: `it("should handle null discount field")`

### 2.3: Run Tests

```
if --no-test:
  Run only the new regression test + tests in affected files
else:
  Run full test suite
```

If tests fail: diagnose and fix. Do not skip.

### 2.4: CQ Critical Gates Check

Abbreviated CQ eval — only the safety-critical gates on changed code:

| Gate | Check |
|------|-------|
| CQ3 | Input validated at the fix boundary? |
| CQ5 | No sensitive data exposed in fix? |
| CQ8 | Error handling correct in fix? |
| CQ10 | Nullable values guarded? |
| CQ14 | Fix doesn't introduce duplication? |

Score each 1/0 with file:line evidence. Any 0 = fix before proceeding.

---

## Phase 3: Verify & Ship

### 3.1: Final Verification

- Regression test passes
- All tests pass (or affected tests if `--no-test`)
- CQ critical gates all = 1

### 3.2: Commit

```bash
git add [files]
git commit -m "fix: [description]

Root cause: [one line]
Affected: [file:line]
Regression test: [test file]"
```

### 3.3: Ship Options

Present options:
- **"Cherry-pick to [base]"** — `git checkout [base] && git cherry-pick [commit]`
- **"Create PR"** — push branch, create PR targeting base branch
- **"Just commit"** — leave on hotfix branch for manual merge

If `--deploy`: after merge, print `Next: run zuvo:deploy to push to production`

---

## Output Block

```
----------------------------------------------------
HOTFIX COMPLETE
  Branch:       hotfix/2026-04-03-payment-null
  Root cause:   PaymentService.processDiscount():142 — null check missing on discount
  Fix:          src/services/payment.ts:142 — added optional chaining
  Test:         src/services/__tests__/payment.hotfix.test.ts
  Files:        1 production, 1 test
  CQ (critical): CQ3:1 CQ5:1 CQ8:1 CQ10:1 CQ14:1
  Status:       [cherry-picked / PR #N created / committed]
----------------------------------------------------
```

---

## Auto-Docs

After output block, update per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the hotfix: root cause, files changed, resolution.
- **api-changelog.md**: Update if fix changed API behavior.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with root cause summary and verdict.
- **Active Work**: Update with hotfix branch status.

---

## Run Log

Log this run to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`:

| Field | Value |
|-------|-------|
| SKILL | `hotfix` |
| CQ_SCORE | `critical-5/5` (abbreviated check) |
| Q_SCORE | `-` |
| VERDICT | PASS if fix verified, FAIL if tests still failing |
| TASKS | Number of production files changed |
| DURATION | `-` |
| NOTES | `fix: [root cause summary]` (max 80 chars) |

---

## Next-Action Routing

| Situation | Recommendation |
|-----------|---------------|
| Root cause unclear | `zuvo:debug` for investigation |
| >3 files affected | `zuvo:build` or `zuvo:brainstorm` pipeline |
| Need post-mortem | `zuvo:incident` for full timeline + action items |
| Ready to deploy | `zuvo:deploy` |
| Need broader test coverage | `zuvo:write-tests` for affected module |
