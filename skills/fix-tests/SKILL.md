---
name: fix-tests
description: >
  Batch repair of systematic test quality issues. Detects anti-patterns
  across the test suite, then fixes one pattern at a time with production
  context. Modes: --triage (scan all patterns, report counts), --pattern
  [ID] [path] (fix specific pattern), --dry-run (preview changes),
  --bundle-gates (fix pattern plus adjacent quality gaps).
---

# zuvo:fix-tests — Batch Test Repair

Fixes systematic test quality problems in batches. Targets one anti-pattern at a time, reads production context for each affected file, rewrites the broken assertions, and verifies the fixes pass.

**Scope:** Post-generation test suites where the same anti-pattern appears across many files. One pattern per run, applied surgically to every matching file.
**Out of scope:** Writing tests from scratch (use `zuvo:write-tests`), auditing test quality without fixing (use `zuvo:test-audit`), general code review (use `zuvo:review`).

## Argument Parsing

Parse `$ARGUMENTS` for mode, pattern ID, and scope:

| Argument | Behavior |
|----------|----------|
| _(empty)_ or `--triage` | Scan all known anti-patterns, report counts, ask which to fix |
| `--pattern [ID]` | Fix the specified pattern across all matching test files |
| `--pattern [ID] [path]` | Fix the pattern, scoped to the given directory |
| `--dry-run` | Show triage counts and affected files, do not modify anything |
| `--bundle-gates` | When fixing a pattern, also apply adjacent quality gates (Q7 error tests, Q12 symmetry) |

Default with no arguments: `--triage`.

### Supported Patterns

| ID | Name | What it fixes |
|----|------|---------------|
| P-41 | Loading-only assertions | Tests that only check `state.loading` instead of verifying payload and state fields |
| P-40 | Wrong initial state | Tests using incorrect initialState shape, missing fields or wrong defaults |
| P-43 | getByTestId overuse | Brittle testId selectors where semantic queries (getByRole, getByLabelText) are available |
| P-44 | Missing rejected state | Async thunks with no rejection test -- adds mockRejectedValue paths |
| P-45 | Shallow empty state | Empty-state tests that only assert absence (not.toBeInTheDocument) without verifying placeholder content |
| P-46 | No validation recovery | Form tests that show validation errors but never test clearing them |
| P-62 | Over-mocking | Files with more than 15 mock declarations -- consolidate or replace with real implementations |
| P-63 | Silent E2E conditionals | E2E tests with `if (isVisible())` guards that silently skip assertions |
| P-64 | Hardcoded credentials | Passwords and secrets as string literals in test files |
| P-65 | Under-tested API routes | Route handler tests with fewer than 6 test cases |
| P-68 | Mocking own code | Mocks of internal services/utils that could use real implementations |
| P-70 | Tautological oracle | Expected values computed from the same formula as the production code |
| G-43 | Opaque dispatch | Tests asserting `typeof dispatch === 'function'` instead of verifying dispatch arguments |
| AP2 | Conditional assertions | `if (x) { expect(...) }` patterns that silently skip when the condition is false |
| AP5 | as-any mock casts | `as any` or `as never` casts on mock objects instead of typed factories |
| AP10 | Delegation-only | `toHaveBeenCalled()` as the sole assertion without `toHaveBeenCalledWith` or return-value checks |
| AP14 | toBeDefined sole assertion | `toBeDefined()` or `toBeTruthy()` as the only assertion in a test |
| AP21 | Raw mock.calls index | Direct `.mock.calls[0][1]` access instead of `toHaveBeenNthCalledWith` |
| NestJS-P3 | Self-mock | `spyOn(service, method)` mocking the service under test instead of its dependencies |
| Q3-CalledWith | Bare toHaveBeenCalled | Files with toHaveBeenCalled() but zero CalledWith assertions |
| Q7-API | No error tests | API wrapper test files with zero mockRejectedValue / error path tests |
| Q17-passthrough | No arg verification | NestJS controller tests with return-value assertions but no CalledWith on the service |

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch, path resolution, and progress tracking.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Step | Task | CodeSift tool | Fallback |
|------|------|--------------|----------|
| 1 | Pattern scanning | `search_text(repo, query=<regex>, regex=true, file_pattern="*.test.*")` | Grep |
| 2 | Find production counterpart | `find_references(repo, symbol_name=<import>)` | Directory convention matching |
| 3 | Read production context | `get_file_outline(repo, file_path)` + `get_symbols(repo, symbol_ids=[...])` | Read full file |
| 3 | State shape for Redux | `get_symbol(repo, "initialState")` | Read the slice file |
| 3 | Component elements | `get_symbol(repo, <component_jsx_return>)` | Read the component |
| 3 | Batch function reads | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |

---

## Mandatory File Reading

Before starting, read the applicable files:

**Core (always required):**

```
CORE FILES LOADED:
  1. ../../rules/testing.md                    -- [READ | MISSING -> STOP]
  2. ../../shared/includes/quality-gates.md    -- [READ | MISSING -> STOP]
  3. ../../shared/includes/run-logger.md       -- [READ | MISSING -> STOP]
  4. ../../shared/includes/knowledge-prime.md  -- READ/MISSING
  5. ../../shared/includes/knowledge-curate.md -- READ/MISSING
  6. ../../shared/includes/retrospective.md    -- RETRO PROTOCOL
```

**Conditional (loaded when the pattern requires domain knowledge):**

| File | Load when |
|------|-----------|
| Domain test patterns (Redux) | Pattern is P-40, P-41, P-44, G-43 |
| Domain test patterns (NestJS) | Pattern is NestJS-P3, Q17-passthrough |

---

## Artifact Contract

Session progress persists to `memory/fix-tests-progress.md`:

```
# Fix-Tests Progress
| Pattern | Files Found | Fixed | Skipped | Needs Review | Last Run |
|---------|------------|-------|---------|-------------|----------|
```

Triage populates Files Found. The report step updates Fixed/Skipped/Needs Review and Last Run.

---

## Multi-Pattern Loop

**Loop ownership by environment:**

| Environment | Who owns the loop | Agent behavior |
|-------------|------------------|----------------|
| Claude Code | Agent (after Step 6) | Complete pattern, check remaining, start next if needed |
| Codex | External loop | Complete one pattern, stop. Loop restarts if patterns remain |
| Cursor | External hook | Complete one pattern, stop. Hook restarts if patterns remain |

---

## Knowledge Prime

Run the knowledge prime protocol from `knowledge-prime.md`:
```
WORK_TYPE = "implementation"
WORK_KEYWORDS = <keywords from user request>
WORK_FILES = <files being touched>
```

---

## Step 1: Triage

Scan for all supported patterns using grep (or CodeSift search_text). Report counts per pattern before doing any fixing.

For each pattern, run the detection command and count matches. Report format:

```
TRIAGE RESULTS
-----
  AP10 (delegation-only):    [N] files -> [Fix | Skip]
  AP14 (toBeDefined sole):   [N] files -> [Fix | Skip]
  P-41 (loading-only):       [N] hits in [M] files -> [Fix | Skip]
  Q7-API (no rejection):     [N] api wrapper files -> [Fix | Skip]
  ...
-----
```

**Triage mode:** Show full report, ask "Which patterns to fix? (all / list IDs)".
**Pattern mode:** Report only the count for the specified pattern, proceed to Step 2.
**Dry-run mode:** Show triage report and affected file list, then STOP.

---

## Step 2: Identify Affected Files

For the chosen pattern, collect the specific file paths (not just counts).

For each affected test file, find its production counterpart:
- Convention matching: `profileSlice.test.ts` maps to `profileSlice.ts`
- `__tests__/` convention: `__tests__/MyComponent.test.tsx` maps to `MyComponent.tsx`
- If production file not found:
  - Patterns needing production context (P-41, G-43, P-40, P-43, P-44, P-45, P-46, AP10, NestJS-P3, AP14, Q7-API, AP5, Q3-CalledWith, P-65, Q17-passthrough, P-68): mark as ORPHAN, skip
  - Mechanical patterns (AP2, AP21, P-62, P-63, P-64): proceed without production file

---

## Step 3: Read Production Context

For each (test file, production file) pair, extract the information needed for the fix. What to read depends on the pattern:

| Pattern | Production context needed |
|---------|--------------------------|
| P-41 | State interface -- all fields and their types |
| G-43 | Component -- which thunks are dispatched and with what arguments |
| P-40 | Slice initialState -- exact shape and default values |
| P-43 | Component JSX -- roles and labels on interactive elements |
| P-44 | Thunk definitions -- what each createAsyncThunk returns and rejects with |
| P-45 | Component -- what renders in the empty state (text, placeholders) |
| P-46 | Form component -- validation errors and their clear conditions |
| AP10 | Service method signatures -- parameter types and return types |
| NestJS-P3 | Service -- which methods are dependencies vs owned logic |
| Q7-API | API wrapper -- which methods make external calls and what errors they can throw |
| Q3-CalledWith | Production method -- what arguments it passes to its dependencies |
| P-65 | Route handler -- auth, validation, and error paths |
| Q17-passthrough | Controller + service -- what arguments flow from controller to service |
| AP5 | Type definitions of mocked dependencies |
| P-68 | Service implementation -- determine if the mocked code can run without infrastructure |
| P-70 | Spec or domain knowledge -- determine correct expected values independent of implementation |

---

## Step 4: Batch Fix

Group affected files into batches of 5. Process each batch:

1. Read the test file
2. Identify every instance of the target pattern
3. Rewrite each instance using the production context from Step 3
4. Preserve surrounding test structure -- do not reorganize unrelated code

### Fix Principles

- Replace, do not append. A fixed assertion replaces the broken one -- do not leave the old assertion alongside the new one.
- Use production-derived values. Every rewritten assertion must reference real fields, real types, and real behaviors from the production code.
- Preserve test names if the intent was correct. Only rename tests when the original name described the wrong behavior.
- When `--bundle-gates` is active: after fixing the target pattern, scan each modified file for Q7 (missing error path) and Q12 (missing symmetry) violations. Fix those too.

---

## Step 5: Verify

Run the modified test files:

```bash
[test runner] [modified test files]
```

All tests must pass. If a fix introduces a failure:

1. Read the error message
2. Determine if the failure is from the fix (incorrect assertion) or from a real production bug discovered by the stronger assertion
3. If incorrect assertion: revise the fix
4. If production bug discovered: note it in the report and persist to backlog

### Step 5b: Adversarial Review (MANDATORY — do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --mode test
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** — fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** — known concerns (max 3, one line each).

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this — if true, it's serious."

"Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, add it to backlog with file:line. The adversarial review found a real problem — don't dismiss it just because it existed before your changes.

---

## Step 6: Report

Print the summary for this pattern:

```
FIX-TESTS: [PATTERN ID] COMPLETE
-----
Files fixed:     [N]
Files skipped:   [N] (orphan: [N], already-clean: [N])
Needs review:    [N] (production bugs discovered)
Tests passing:   [N]/[N]
-----
```

Update `memory/fix-tests-progress.md` with the results.

### Backlog Persistence

Read `../../shared/includes/backlog-protocol.md`.

Persist any production bugs discovered during fixing, or files that could not be fixed automatically, to `memory/backlog.md`.

### Knowledge Curation

After work is complete, run the knowledge curation protocol from `knowledge-curate.md`:
```
WORK_TYPE = "implementation"
CALLER = "zuvo:fix-tests"
REFERENCE = <git SHA or relevant identifier>
```

### Multi-Pattern Continuation

If fixing all patterns: check which patterns remain in the triage list. If any are left, proceed to Step 2 for the next pattern. If none remain, print the full session summary:

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to session complete.

```
FIX-TESTS SESSION COMPLETE
-----
Patterns fixed:  [list]
Total files:     [N] fixed, [N] skipped
Bugs discovered: [N] (see backlog)
Run: <ISO-8601-Z>	fix-tests	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use `N-patterns` (number of patterns fixed) or `triage` (triage-only run).
`<Q>`: Q score if Q gates were evaluated, otherwise `-`.
`<TASKS>`: number of files fixed.
