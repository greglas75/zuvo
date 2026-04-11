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

### PHASE 0 — Bootstrap (always, before reading production file)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
```

This is the ONLY file loaded before reading the production file. Do NOT load test-contract, quality-gates, testing rules, or any other include at this point — you don't know the code type yet.

### PHASE 0.5 — Classify (read production file, determine loading tier)

After CodeSift setup, read the production file fully. Classify it per `test-code-types.md` classification table (memorized from prior sessions or read on first encounter):

- **Code type:** VALIDATOR / SERVICE / CONTROLLER / HOOK / PURE / COMPONENT / GUARD / API-CALL / ORCHESTRATOR / STATE-MACHINE / ORM-DB
- **Complexity:** THIN / STANDARD / COMPLEX
- **Testability:** UNIT_MOCKABLE / UNIT_REFLECTION / NEEDS_INTEGRATION / MIXED

Determine loading tier:

```
IF code_type IN (PURE, VALIDATOR) AND complexity == THIN       → LIGHT
IF code_type IN (PURE, VALIDATOR) AND complexity == STANDARD   → STANDARD
IF code_type IN (STATE-MACHINE) AND complexity == THIN         → LIGHT
IF code_type IN (COMPONENT, HOOK)                              → COMPONENT
IF code_type IN (CONTROLLER, ORCHESTRATOR)                     → HEAVY
IF complexity == COMPLEX                                       → HEAVY
ELSE                                                           → STANDARD
```

When classification is ambiguous, default to STANDARD (loads more than LIGHT, less than HEAVY).

Print: `[CLASSIFIED] {file}: {code_type} {complexity} → tier {TIER}`

### PHASE 1 — Conditional Load (based on classification tier + detected stack)

Load ONLY the includes matching the detected tier AND stack. Print READ/SKIP status for each.

**Always load (all tiers, all stacks):**

| Include | LIGHT | STANDARD | HEAVY | COMPONENT |
|---------|-------|----------|-------|-----------|
| `../../shared/includes/test-contract.md` | Sections 1,3,6 only | Full | Full | Full |
| `../../shared/includes/test-blocklist.md` | Full | Full | Full | Full |
| `../../shared/includes/quality-gates.md` | Q1-Q19 only* | Q1-Q19 only* | Q1-Q19 only* | Q1-Q19 only* |
| `../../rules/testing.md` | Full | Full | Full | Full |
| `../../shared/includes/test-mock-safety-core.md` | Full | Full | Full | Full |
| `../../shared/includes/test-code-types-core.md` | Full | Full | Full | Full |

**Stack-specific (load ONLY matching stack):**

| Include | LIGHT | STANDARD | HEAVY | COMPONENT |
|---------|-------|----------|-------|-----------|
| `test-mock-safety-js.md` OR `test-mock-safety-php.md` | **SKIP** | Full | Full | **SKIP** |
| `test-code-types-js.md` OR `test-code-types-php.md` | **SKIP** | Full | Full | **SKIP** |
| `../../shared/includes/test-edge-cases.md` | **SKIP** | Full | Full | **SKIP** |

**Stack detection:** `composer.json` → PHP, `package.json` → JS/TS, `pyproject.toml` → Python. Load the matching `-js.md` or `-php.md` file. Never load both.

\* **quality-gates.md:** Read ONLY from `## Q1-Q19: Test Quality Gates` to end of file. Skip CQ1-CQ28.

```
PHASE 1 — LOADED:
  2. test-contract.md              -- [READ]
  3. test-blocklist.md             -- [READ]
  4. quality-gates.md              -- [READ Q1-Q19 only]
  5. testing.md                    -- [READ]
  6. test-mock-safety-core.md      -- [READ]
  7. test-code-types-core.md       -- [READ]
  8. test-mock-safety-{stack}.md   -- [READ | SKIP — per tier]
  9. test-code-types-{stack}.md    -- [READ | SKIP — per tier]
  10. test-edge-cases.md           -- [READ | SKIP — per tier]
```

### DEFERRED — Load at completion (Step 5)

```
  9. ../../shared/includes/run-logger.md           -- [READ at Step 5]
  10. ../../shared/includes/retrospective.md        -- [READ at Step 5]
```

---

## Phase 0: Bootstrap + Classify (runs once per file)

1. **CodeSift setup** per `codesift-setup.md`. Note repo identifier.
2. **Read production file.** Read the target file fully. This happens BEFORE loading any other includes.
3. **Classify** per PHASE 0.5 above. Determine code type, complexity, testability, and loading tier.
4. **Load conditional includes** per PHASE 1 table above. Print READ/SKIP status for each.
5. **Dynamic context retrieval (when CodeSift available):** Run targeted retrieval dimensions for the target file. Which dimensions run depends on the tier:
   - **LIGHT tier:** D1 only (file is self-contained, no complex mocks)
   - **STANDARD tier:** D1 + D2 (conditional) + D3 (conditional) + D4
   - **HEAVY tier:** D1 + D2 + D3 + D4
   - **COMPONENT tier:** D1 + D4 (setup comes from exemplar, skip D2-D3)
   
   Skip any dimension that times out or fails — partial context is better than none.
   
   Print: `[CONTEXT] Tier: {TIER}, exemplar={path}, {N} import mocks, {N} signatures`

   **Retrieval queries are stack-aware.** Detect stack from Phase 0 (package.json → JS/TS, composer.json → PHP, pyproject.toml → Python). Use the matching query set below.

   **Dimension 1 — Exemplar test (ALL tiers):** Find an existing test file to use as pattern reference.
   
   JS/TS stack:
   ```
   find_references(repo, "<main_export_of_target_file>")
   → look for *.test.* or *.spec.* files in results
   → fallback: search_text(repo, query: "describe.*<ClassName>", file_pattern: "**/__tests__/*")
   → fallback: search_text(repo, query: "describe", file_pattern: "**/<same_module>/__tests__/*")
   ```
   
   PHP stack:
   ```
   search_text(repo, query: "extends Unit|extends TestCase", file_pattern: "tests/**/*Test.php", max_results: 5)
   → prefer test file in same module: tests/unit/<ModuleName>*Test.php
   → fallback: search_text(repo, query: "createMock|getMockBuilder", file_pattern: "tests/**/*Test.php", max_results: 3)
   ```
   
   Python stack:
   ```
   search_text(repo, query: "class Test<ClassName>|def test_<function>", file_pattern: "tests/**/test_*.py|**/tests.py", max_results: 5)
   → fallback: search_text(repo, query: "mock.patch|MagicMock", file_pattern: "tests/**/test_*.py", max_results: 3)
   ```
   
   Read the exemplar fully — it shows how THIS project writes tests (mock style, describe/class structure, import conventions, setup patterns).
   Print: `[CONTEXT] Exemplar: {path}` or `[CONTEXT] No exemplar found — using generic patterns.`

   **Dimension 2 — Import mocks (STANDARD+ tiers, skip for LIGHT/COMPONENT):** Also skip if Dimension 1 found an exemplar in the **same module** (exemplar already shows mock patterns).
   For **at most 5** imports from the target file (skip vendor/node_modules, skip type-only imports):
   
   JS/TS: `search_text(repo, query: "vi.mock.*<import_path>|jest.mock.*<import_path>", file_pattern: "**/__tests__/*|*.test.*|*.spec.*", max_results: 3)`
   PHP: `search_text(repo, query: "createMock.*<ClassName>|getMockBuilder.*<ClassName>", file_pattern: "tests/**/*Test.php", max_results: 3)`
   Python: `search_text(repo, query: "mock.patch.*<module_path>|MagicMock.*<ClassName>", file_pattern: "tests/**/test_*.py", max_results: 3)`
   
   Collect: which dependencies are mocked, what mock patterns are used.
   Print: `[CONTEXT] Import mocks: {N} dependencies with existing mock patterns.` or `[CONTEXT] D2 skipped — exemplar covers mock patterns.`

   **Dimension 3 — Test setup (STANDARD+ tiers, skip for LIGHT/COMPONENT):** Also skip if CLAUDE.md describes test infrastructure OR if exemplar test already imports setup helpers.
   
   JS/TS: `search_text(repo, query: "setupFiles", file_pattern: "vitest.config.*|jest.config.*")`
   PHP: `search_text(repo, query: "_bootstrap|Helper|ActorActions", file_pattern: "tests/**/*.php|codeception.yml")`
   Python: `search_text(repo, query: "conftest|fixtures|factory", file_pattern: "tests/**/conftest.py|pytest.ini|setup.cfg")`
   
   Extract setup file paths → read their outlines. These contain global mocks, fixtures, helpers.
   Print: `[CONTEXT] Setup: {N} setup files.` or `[CONTEXT] D3 skipped — setup info available from exemplar/CLAUDE.md.`

   **Dimension 4 — Hub signatures (STANDARD+ and COMPONENT tiers, skip for LIGHT):** What do the target file's imported utilities look like?
   Extract import/use names from target file → query signatures:
   ```
   codebase_retrieval(repo, token_budget=1000, queries=[
     {type: "symbols", query: "<imported_function_or_class_names>", detail_level: "compact"}
   ])
   ```
   This gives function/method signatures without full source.
   Print: `[CONTEXT] Signatures: {N} utility functions.`

   **Error handling per dimension:** If any query times out or returns an error, print `[CONTEXT] Dimension N skipped — {reason}.` and continue with remaining dimensions.

   **If CodeSift unavailable:** Skip all 4 dimensions. Print: `[CONTEXT] CodeSift unavailable — using legacy detection.`

6. **Stack detection:** Read package.json/tsconfig/composer.json. Detect test runner (vitest/jest/phpunit). Find existing test patterns (DB helpers, factory functions, mock conventions). If Dimension 1 found an exemplar, stack is already implied — but confirm test runner from config.
7. **Baseline test run:** execute test suite, record pre-existing failures. These are ignored in verification.
8. **Build queue:**
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

The production file was already read and classified in Phase 0.5. **If a test file already exists, read it now.** Assess existing test quality:

- **No test file** → action: CREATE
- **Test file exists, quality OK** (behavioral assertions, no anti-patterns) → action: ADD TO (extend with missing coverage)
- **Test file exists, quality BAD** (fragile string tests, tautological oracles, security theatre, duplicated positives, structural tests that duplicate behavioral ones) → action: **REWRITE**. Fix the whole file, not just add tests. Net test count MAY decrease. Remove anti-patterns, consolidate with it.each, keep only behavioral tests.

**Do NOT add good tests on top of bad tests.** If existing tests are weak, fix them first. "ONE file, FULL pipeline" means the WHOLE test file, not just the gap you were sent to fix.

**Barrel file detection:** If the file contains ONLY `export { X } from './sub-module'` lines (zero owned logic), it is a barrel/re-export file. Do NOT write delegation tests for it — expand the queue to the sub-modules it re-exports from. Print: `[BARREL] {file} is a re-export barrel — expanding to {N} sub-modules.`

**If exemplar test loaded in Phase 0 (Dimension 1):** Use it as the primary pattern reference.
First, **extract these patterns from the exemplar** before planning tests:
- **Cleanup pattern:** Does it use `afterEach(cleanup)`? `afterAll`? Nothing?
- **Matcher library:** testing-library (`screen.getByRole`) vs enzyme (`wrapper.find`) vs direct (`container.querySelector`)?
- **Async pattern:** `findBy` (auto-wait) vs `waitFor` vs `act`?
- **Mock factory style:** inline `vi.mock` vs shared factory vs `__mocks__/` directory?
- **Import conventions:** path aliases, relative imports, barrel imports?

Then apply:
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

Classification already done in Phase 0.5. Includes already loaded per tier in Phase 1.

Plan: target test count (from code-type formula), describe/it outline, mock strategy. For STANDARD+ tiers, apply edge cases from `test-edge-cases.md` (already loaded in Phase 1).

**PURE optimization (LIGHT tier):** Contract: skip MOCK INVENTORY if only Logger. Keep BRANCHES, ERROR PATHS, EXPECTED VALUES. **Do NOT skip adversarial** — retro shows it catches real bugs even on simple files.

**COMPONENT optimization (COMPONENT tier):** After finding exemplar (D1), extract: cleanup pattern (`afterEach(cleanup)`), matcher library (testing-library vs enzyme), async pattern (`findBy` vs `waitFor` vs `act`). **Do NOT skip adversarial or edge-cases.**

**Test contract output:** Do NOT print the full contract to the conversation. Use it as an internal checklist. Show the user only: branch coverage table + test outline + planned test count. The contract costs ~2K output tokens and the user doesn't read it.

Print: `[file]: [type] [complexity] [testability] → [N] tests planned`

### Step 2: Write

1. **Fill test contract** per `test-contract.md`: BRANCHES, ERROR PATHS, EXPECTED VALUES, MOCK INVENTORY, MUTATION TARGETS, TEST OUTLINE. If 3+ methods share the same control flow pattern (e.g., null guard + try/catch), use **per-pattern mode** from test-contract.md instead of per-branch.
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
  --context "STACK: [language] [version] / [test-framework] [version]. Code type: [type] [complexity] [testability]. Q-GATES: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]" \
  --files "<absolute-path-to-production-file> <absolute-path-to-test-file>"
```

**STACK in context is mandatory.** Without it, reviewers assume JS/TS and generate false positives for PHP/Python mock patterns. Examples:
- `STACK: PHP 8.3 / Codeception 5 / PHPUnit 10`
- `STACK: TypeScript 5.4 / Vitest 2.0`
- `STACK: Python 3.12 / pytest 8.0`

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
Run: <ISO-8601-Z>	write-tests	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
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
