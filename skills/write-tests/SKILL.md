---
name: write-tests
description: >
  Write tests for existing production code. Processes ONE file at a time
  through a full pipeline: analyze, write, verify, adversarial review, log.
  Uses CodeSift for discovery and analysis when available. Modes: [path]
  (specific target), auto (discover and loop until done), --dry-run (plan only).
---

# zuvo:write-tests — Single-File Test Pipeline

Generate high-quality tests for production code. Each file goes through the full pipeline individually — no batching, no skipping verification.

**Scope:** Existing production files with missing or partial test coverage.
**Out of scope:** New feature tests (use `zuvo:build`), mass anti-pattern repair (use `zuvo:fix-tests`), audit without writing (use `zuvo:test-audit`).

## Argument Parsing

| Input | Behavior |
|-------|----------|
| `[file.ts]` | Write tests for one production file |
| `[directory/]` | Write tests for all production files in the directory |
| `auto` | Discover uncovered files, process one at a time until done |
| `--dry-run` | Run Phase 0 + Step 1 for all files, print plan, stop |
| `--no-cache` | Force regeneration of project profile before test planning |

---

## Mandatory File Loading

**Phase 0 (always load):** core files needed before analysis.

```
CORE (Phase 0):
  1. ../../shared/includes/codesift-setup.md      -- [READ|MISSING -> STOP]
  2. ../../shared/includes/test-contract.md        -- [READ|MISSING -> STOP]
  3. ../../shared/includes/test-blocklist.md       -- [READ|MISSING -> STOP]
  4. ../../shared/includes/test-mock-safety.md     -- [READ|MISSING -> STOP] (skip for PURE)
  5. ../../shared/includes/quality-gates.md        -- [READ|MISSING -> STOP]
  6. ../../rules/testing.md                          -- [READ|MISSING -> STOP]

DEFERRED (load at Step 5, NOT Phase 0 — saves ~340 lines × 25 turns in context):
  7. ../../shared/includes/run-logger.md           -- [READ at Step 5]
  8. ../../shared/includes/retrospective.md          -- [READ at Step 5]
```

**Step 1 (load after classification):** based on file complexity.

```
STANDARD+ only (skip for THIN):
  9. ../../shared/includes/test-edge-cases.md      -- [READ|SKIP]
  10. ../../shared/includes/test-code-types.md      -- [READ|SKIP]
```

---

## Phase 0: Setup (runs once)

1. **CodeSift setup** per `codesift-setup.md`. Note repo identifier.
2. **Dynamic context retrieval (when CodeSift available):** Run 4 targeted retrieval dimensions for the target file. Each dimension answers a specific question. Skip any that timeout/fail — partial context is better than none.

   **Dimension 1 — Exemplar test:** Find an existing test file to use as pattern reference.
   ```
   find_references(repo, "<main_export_of_target_file>")
   ```
   Look for `*.test.*` or `*.spec.*` files in the results. If found → this is the exemplar. Read it fully — it shows how THIS project writes tests (mock style, describe structure, import conventions, setup patterns).
   If no test file in references → try: `search_text(repo, query: "describe.*<ClassName>", file_pattern: "**/__tests__/*")`.
   If still nothing → try same code type in same module: `search_text(repo, query: "describe", file_pattern: "**/<same_module>/__tests__/*")`.
   Print: `[CONTEXT] Exemplar: {path}` or `[CONTEXT] No exemplar found — using generic patterns.`

   **Dimension 2 — Import mocks (CONDITIONAL):** Skip if Dimension 1 found an exemplar in the **same module** (exemplar already shows mock patterns). Run only when exemplar is from a different module or not found.
   For **at most 5** imports from the target file (skip node_modules, skip type-only imports):
   ```
   search_text(repo, query: "vi.mock.*<import_path>", file_pattern: "**/__tests__/*|*.test.*|*.spec.*", max_results: 3)
   ```
   Collect: which dependencies are mocked, what mock patterns are used (mockResolvedValue, vi.fn, class mock, etc.).
   Print: `[CONTEXT] Import mocks: {N} dependencies with existing mock patterns.` or `[CONTEXT] D2 skipped — exemplar covers mock patterns.`

   **Dimension 3 — Test setup (CONDITIONAL):** Skip if CLAUDE.md describes test infrastructure OR if exemplar test already imports setup helpers. Run only for first file in queue or when no other context source exists.
   ```
   search_text(repo, query: "setupFiles", file_pattern: "vitest.config.*|jest.config.*")
   ```
   Extract setup file paths from config → read their outlines with `get_file_outline`. These setup files contain global mocks (Sentry, shared-types, etc.) that tests inherit.
   Print: `[CONTEXT] Setup: {N} setup files.` or `[CONTEXT] D3 skipped — setup info available from exemplar/CLAUDE.md.`

   **Dimension 4 — Hub signatures:** What do the target file's imported utilities look like?
   Extract import names from target file → query signatures:
   ```
   codebase_retrieval(repo, token_budget=1000, queries=[
     {type: "symbols", query: "<imported_function_names>", detail_level: "compact"}
   ])
   ```
   This gives function signatures (params + return types) without full source. The LLM knows `isPrismaNotFound(error: unknown): boolean` exists without reading 200 lines.
   Print: `[CONTEXT] Signatures: {N} utility functions.`

   **Error handling per dimension:** If any query times out or returns an error, print `[CONTEXT] Dimension N skipped — {reason}.` and continue with remaining dimensions.

   **If CodeSift unavailable:** Skip all 4 dimensions. Print: `[CONTEXT] CodeSift unavailable — using legacy detection.` Fall to Step 3.

3. **Stack detection:** Read package.json/tsconfig/composer.json. Detect test runner (vitest/jest/phpunit). Find existing test patterns (DB helpers, factory functions, mock conventions). If Dimension 1 found an exemplar, stack is already implied — but confirm test runner from config.
4. **Baseline test run:** execute test suite, record pre-existing failures. These are ignored in verification.
5. **Build queue:**
   - **Explicit mode:** queue = user's target file(s)
   - **Auto mode with CodeSift:** single batch call:
     ```
     codebase_retrieval(repo, token_budget=5000, queries=[
       {type: "dead_code"},
       {type: "hotspots", since_days: 90},
       {type: "references", symbol_names: [exports], file_pattern: "*.test.*"},
       {type: "classify_roles", file_pattern: "src/"}
     ])
     ```
     Dead/leaf symbols with 0 test refs = UNCOVERED. **Priority:** hub symbols first (many connections = failures cascade), then high-churn, then leaf.
   - **Auto mode without CodeSift:** `Glob("src/**/*.ts")` + check for matching `*.test.*` files. Files without test = UNCOVERED.

**`--dry-run` mode:** after building queue, run Step 1 (Analyze) for each file, print classification table, STOP.

---

## Per-File Loop

For each file in the queue, execute Steps 1-5 in order. Do NOT skip any step. Do NOT proceed to the next file until all 5 steps complete.

### Step 1: Analyze

Read the production file fully. **If a test file already exists, read it too.** Classify the production file AND assess existing test quality:

- **No test file** → action: CREATE
- **Test file exists, quality OK** (behavioral assertions, no anti-patterns) → action: ADD TO (extend with missing coverage)
- **Test file exists, quality BAD** (fragile string tests, tautological oracles, security theatre, duplicated positives, structural tests that duplicate behavioral ones) → action: **REWRITE**. Fix the whole file, not just add tests. Net test count MAY decrease. Remove anti-patterns, consolidate with it.each, keep only behavioral tests.

**Do NOT add good tests on top of bad tests.** If existing tests are weak, fix them first. "ONE file, FULL pipeline" means the WHOLE test file, not just the gap you were sent to fix.

**Barrel file detection:** If the file contains ONLY `export { X } from './sub-module'` lines (zero owned logic), it is a barrel/re-export file. Do NOT write delegation tests for it — expand the queue to the sub-modules it re-exports from. Print: `[BARREL] {file} is a re-export barrel — expanding to {N} sub-modules.`

**If exemplar test loaded in Phase 0 (Dimension 1):** Use it as the primary pattern reference:
- Copy mock import style from exemplar (vi.mock paths, mock factory patterns)
- Match describe/it nesting structure
- Reuse setup patterns (beforeEach, afterEach, shared helpers)
- Match assertion style (toEqual vs toBe, exact vs loose)
Do NOT invent new patterns — follow what the exemplar does.

**If import mocks loaded (Dimension 2):** Use discovered mock patterns in MOCK INVENTORY section of test contract. Copy mock patterns from existing project tests, not from memory.

**If hub signatures loaded (Dimension 4):** Reference utility function signatures when planning assertions. Know what `isPrismaNotFound(error)` returns before writing error-path tests.

### Step 1.5: Bug Scan (before writing tests)

You just read the production code. **Before** planning tests, scan for bugs:
- Missing error handling (uncaught promise, empty catch)
- Logic errors (wrong operator, off-by-one, inverted condition)
- Security gaps (missing auth check, unsanitized input, unbounded query)
- Edge cases the code doesn't handle (null, empty, duplicates)

If you find a bug: log it to `memory/backlog.md` with file:line and description. Then write tests that **expose** the bug (test should fail if bug exists, pass if fixed). This catches bugs BEFORE adversarial review instead of wasting ~30K tokens discovering them in pass 2.

Print: `[BUG-SCAN] Found {N} potential issues.` or `[BUG-SCAN] Clean.`

**With CodeSift:** single batch call:
```
codebase_retrieval(repo, token_budget=3000, queries=[
  {type: "outline", file_path: "<file>"},
  {type: "complexity", file_pattern: "<file>"},
  {type: "call_chain", symbol_name: "<main_export>", direction: "callees"}
])
```

**Without CodeSift:** Read the file, count branches manually.

Classify per `test-code-types.md`:
- **Code type:** VALIDATOR / SERVICE / CONTROLLER / HOOK / PURE / COMPONENT / GUARD / API-CALL / ORCHESTRATOR / STATE-MACHINE / ORM-DB
- **Complexity:** THIN / STANDARD / COMPLEX
- **Testability:** UNIT_MOCKABLE / UNIT_REFLECTION / NEEDS_INTEGRATION / MIXED

Plan: target test count (from code-type formula), describe/it outline, mock strategy. For STANDARD+, apply edge cases from `test-edge-cases.md`.

**PURE fast-path:** If code type is PURE (no I/O, no side-effects, no mocks except Logger):
- Skip `test-mock-safety.md` rules (no mocks to verify)
- Skip Dimensions 2-4 in retrieval (self-contained file)
- Shorten test contract to: BRANCHES + EXPECTED VALUES + TEST OUTLINE only (skip ERROR PATHS if no throws, skip MOCK INVENTORY if only Logger)
- Adversarial: 1 pass max (if Q >= 17, skip pass 2)
Print: `[PURE-FAST] Shortened pipeline for pure function.`

Print: `[file]: [type] [complexity] [testability] → [N] tests planned`

### Step 2: Write

1. **Fill test contract** per `test-contract.md`: BRANCHES, ERROR PATHS, EXPECTED VALUES, MOCK INVENTORY, MUTATION TARGETS, TEST OUTLINE.
2. **Check blocklist** per `test-blocklist.md` — verify you are NOT about to write any blocked pattern.
3. **Apply mock rules** per `test-mock-safety.md`.
4. **Write the test file.** Follow the contract and plan exactly.
5. **Run tests:** `[test runner] [test file]`. All new tests must pass. Pre-existing failures ignored. Fix red tests before proceeding.

### Step 3: Verify

1. **Anti-tautology check:** grep test file for mock-return-echoed-in-assertion patterns. Verify every expected value is spec-derived, not implementation-derived. Any tautological oracle found = fix immediately.
   **Exception for THIN delegation:** When code type is THIN and the method body is a single `return delegateFunction(args)`, echo testing IS the behavioral test — the facade's contract is to forward unchanged. `expect(result).toBe(mockReturnValue)` combined with `CalledWith` is correct, not tautological. P-70 does NOT apply to pure delegation pass-through.
2. **Q1-Q19 self-eval** per `quality-gates.md`. Print scorecard with evidence:
   ```
   Self-eval: Q1=1 Q2=1 Q3=0 ... → [N]/19 [PASS|FIX|REWRITE]
   Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]
   ```
   Any critical gate at 0: fix immediately and re-score.

No sub-agent dispatch. Step 4 (4 adversarial passes with different models) provides true independent verification — stronger than same-model sub-agent.

### Step 4: Adversarial Review (iterative, complexity-tiered)

Run adversarial passes sequentially, one RANDOM provider per pass (`--rotate`). Each pass sees the FIXED code from previous passes. Early exit when a pass returns 0 findings. Run until clean or max passes exhausted (whichever first).

**Pass count by complexity:**

| Complexity | Max passes | Rationale |
|-----------|-----------|-----------|
| THIN | 1 | Sanity check — wiring correctness only |
| STANDARD | 2 | Pass 1 finds gaps, pass 2 verifies fixes |
| COMPLEX | 2 + optional 3rd | Extra pass ONLY IF pass 2 found CRITICAL with high confidence |

Agent data shows passes 3-4 yield 0 new findings and cost ~60K tokens. 99% of value is in first 2 passes.

**Input: production + test file** (not just diff). Reviewer needs to see what's being tested to find gaps:

```bash
adversarial-review --rotate --mode test \
  --context "Code type: [type] [complexity] [testability]. Q-GATES: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]" \
  --files "<absolute-path-to-production-file> <absolute-path-to-test-file>"
```

**Always use absolute paths for --files.** Relative paths fail silently.

The provider sees both files and focuses on gaps between production behavior and test coverage. Without production code, reviewer can't detect missing ordering tests, auth boundary gaps, or untested error messages.

**Pass sequence with structured context (prevents repetition):**

```
Pass 1:
  adversarial-review --rotate --mode test --context "..." --files "<prod> <test>"
  Note which provider was used (from stderr output).
  → fix CRITICAL/WARNING → re-run tests

Pass 2:
  adversarial-review --rotate --exclude <pass-1-provider> --mode test \
    --context "... FIXED: [...]. REJECTED: [...]. KNOWN: [...]." \
    --files "<prod> <test>"
  → fix findings → re-run tests (guaranteed different provider)

Pass 3 (COMPLEX only, if pass 2 had CRITICAL):
  adversarial-review --rotate --exclude <pass-2-provider> --mode test \
    --context "..." --files "<prod> <test>"
```

**Context rules:**
- FIXED findings must NOT be re-raised. If reviewer repeats a fixed finding, ignore it.
- REJECTED findings have a **severity cap**: `REJECTED: [finding] — max re-raise: INFO`. If reviewer escalates a rejected finding above the cap (e.g. INFO → CRITICAL), auto-ignore. This prevents adversarial from overriding conscious scope decisions.
- Each pass adds its own fixes/rejections to the context for the next pass.
- Early exit: 0 new findings (not counting repeats of FIXED/REJECTED).

**Stub fidelity rule for ORCHESTRATOR:** Route module stubs MUST use `all()` (catch-all). Testing HTTP methods (GET vs POST) is the responsibility of route module tests, not orchestrator tests. If adversarial flags "stubs don't verify HTTP methods" — REJECT with "scope mismatch, route module responsibility".

If `adversarial-review` is not found: check `../../scripts/adversarial-review.sh`. If missing entirely, mark file SKIPPED_REVIEW and proceed.

**Fix policy per pass:**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING (<10 lines)** | Fix immediately. |
| **WARNING (>10 lines)** | Add to backlog with file:line. |
| **INFO** | Known concerns (max 3). |
| **0 findings** | Early exit — stop passes, file is clean. |
| **After pass 4 with unresolved CRITICAL** | Mark file **FAILED** in coverage.md. Backlog findings. |
| **Provider unavailable on all passes** | Mark file **SKIPPED_REVIEW** in coverage.md. |

### Step 5: Log

Update `memory/coverage.md`:
```
| File | Status | Tests | Q Score | Adversarial | Date |
```

Statuses: `PASS`, `FAILED`, `SKIPPED_REVIEW`

Print per-file summary: `[status] [file] — [N] tests, Q [N]/19, adversarial: [clean|N findings|skipped]`

**→ NEXT file in queue.**

---

## Completion (after queue empty)

1. **Backlog persistence:** write unfixed issues to `memory/backlog.md`
2. **Knowledge curation** per `knowledge-curate.md`

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
This step is MANDATORY — do not skip it. Write the retro BEFORE the terminal report below.

3. **Report:**

```
WRITE-TESTS COMPLETE
-----
Files tested:  [N] ([M] new, [K] extended, [J] fixed)
Tests written: [N] total
Q gates:       [N]/19 avg (critical gates: all pass)
Failures:      pre-existing: [N], new: 0
FAILED files:  [list or "none"]
SKIPPED_REVIEW: [list or "none"]
Run: <ISO-8601-Z>	write-tests	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>
-----
```

Append `Run:` line to log file per `run-logger.md`.

**Do NOT print WRITE-TESTS COMPLETE if any file has no status in coverage.md.**

---

## Resume / Crash Recovery

On start, read `memory/coverage.md`:

| Status | Resume action |
|--------|---------------|
| PASS | Skip |
| FAILED | Skip (already backlocked) |
| SKIPPED_REVIEW | Re-process Step 4 only (adversarial) |
| (absent) | Process from Step 1 |

If a test file exists on disk but file is absent from coverage.md → partial run. Check if file was auto-generated (contains `// Generated by zuvo:write-tests` header). If yes, delete and re-process from Step 1. If no (pre-existing/manual test), assess quality in Step 1 and choose ADD TO or REWRITE.

Auto mode: re-run CodeSift discovery to rebuild priority queue (queue order not persisted).

---

## Principles

1. Read production code before planning tests. Every assertion traces to real behavior.
2. Test depth matches complexity. A 25-line wrapper does not need 30 edge-case tests.
3. Test what the code OWNS, mock what it DELEGATES.
4. ONE file, FULL pipeline. No batching. No skipping steps.
5. Adversarial review is step 4 of 5 — not optional, not at the end.
