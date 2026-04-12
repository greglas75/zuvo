---
name: write-tests
description: >
  Write tests for existing production code. Processes ONE file at a time
  through a full pipeline: analyze, write, verify, blind coverage audit,
  adversarial review, log. Uses CodeSift for discovery and analysis when
  available. Modes: [path] (specific target), auto (discover and loop until
  done), --dry-run (plan only; skips suite verification).
---

# zuvo:write-tests — Single-File Test Pipeline

Generate high-quality tests for production code. Each file goes through the full pipeline individually — no batching of files or pipeline steps, no skipping verification in normal mode, no skipping coverage audit.

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

`--no-cache` clears cached project-profile and queue hints before discovery/classification.

---

## Mandatory File Loading

### PHASE 0 — Bootstrap (always, before reading production file)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> DEGRADED]
```

This is the ONLY file loaded before reading the production file. Do NOT load test-contract, quality-gates, testing rules, or any other include at this point — you don't know the code type yet.

If `codesift-setup.md` is missing, print `[CONTEXT] codesift-setup missing — assuming CodeSift unavailable and continuing in degraded mode.` Continue the run with legacy detection and native tools. Do not stop the file solely because the bootstrap include is absent.

### PHASE 0.5 — Classify (read production file, determine loading tier)

After CodeSift setup, read the production file fully. Then read `../../shared/includes/test-code-types.md` and classify from that file's canonical table. Do NOT classify from memory.

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

If an include is missing:
- print `[PHASE1] MISSING: <file> — continuing with degraded rules`
- continue loading the remaining includes
- after Phase 1, print `loaded=<N>/<M>` for the files expected for this tier/stack
- if fewer than half of expected includes loaded, print `[WARN] Low include availability — coverage planning and Q-score confidence are reduced for this file. Do not overclaim clean states.`

**Always load (all tiers, all stacks):**

| Include | LIGHT | STANDARD | HEAVY | COMPONENT |
|---------|-------|----------|-------|-----------|
| `../../shared/includes/test-contract.md` | Full | Full | Full | Full |
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
| `../../shared/includes/test-edge-cases.md` | **SKIP** | Full | Full | Full |

**Stack detection:** resolve stack per target file using the nearest manifest:

- nearest `package.json` => JS/TS
- nearest `composer.json` => PHP
- nearest `pyproject.toml` => Python (core-only mode: no Python-specific `test-mock-safety-*` or `test-code-types-*` includes exist yet)

If multiple manifests are equally near, prefer `package.json` > `composer.json` > `pyproject.toml` and print the conflict decision.

Load at most one stack-specific include family. Python uses `test-mock-safety-core.md`, `test-code-types-core.md`, and `test-edge-cases.md`; rows 8-9 are `SKIP` until Python-specific split includes exist.

\* **quality-gates.md:** Read ONLY from `## Q1-Q19: Test Quality Gates` to end of file. Skip CQ1-CQ28.

```
PHASE 1 — LOADED:
  2. test-contract.md              -- [READ]
  3. test-blocklist.md             -- [READ]
  4. quality-gates.md              -- [READ Q1-Q19 only]
  5. testing.md                    -- [READ]
  6. test-mock-safety-core.md      -- [READ]
  7. test-code-types-core.md       -- [READ]
  8. test-mock-safety-{stack}.md   -- [READ | SKIP — per tier/stack]
  9. test-code-types-{stack}.md    -- [READ | SKIP — per tier/stack]
  10. test-edge-cases.md           -- [READ | SKIP — per tier]
```

### DEFERRED — Load after queue empty (Completion only, once per run)

```
  D1. ../../shared/includes/run-logger.md           -- [READ at completion]
  D2. ../../shared/includes/retrospective.md        -- [READ at completion]
  D3. ../../shared/includes/knowledge-curate.md     -- [READ at completion]
```

---

## Phase 0: Bootstrap + Classify (baseline once per run, classification once per file)

1. **CodeSift setup** per `codesift-setup.md`. Note repo identifier.
2. **Read production file.** Read the target file fully. This happens BEFORE loading any other includes.
3. **Detect stack** per the nearest-manifest rule above. If target file extension conflicts with the manifest winner, the target file extension wins. Record the final stack before Phase 1 loading.
4. **Classify** per PHASE 0.5 above. Determine code type, complexity, testability, and loading tier.
5. **Load conditional includes** per PHASE 1 table above. Print READ/SKIP status for each.
6. **Dynamic context retrieval (when CodeSift available):** Run targeted retrieval dimensions for the target file. Which dimensions run depends on the tier:
   - **LIGHT tier:** D1 only (file is self-contained, no complex mocks)
   - **STANDARD tier:** D1 + D2 (conditional) + D3 (conditional) + D4
   - **HEAVY tier:** D1 + D2 + D3 + D4
   - **COMPONENT tier:** D1 + D4 (setup comes from exemplar, skip D2-D3)
   
   Skip any dimension that times out or fails — partial context is better than none.
   
   Print: `[CONTEXT] Tier: {TIER}, exemplar={path}, {N} import mocks, {N} signatures`

   **Retrieval queries are stack-aware.** Use the stack resolved in Phase 0 Step 3. Use the matching query set below.

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

7. **Test runner refinement:** Read the nearest manifest/config for the resolved stack. Detect test runner (vitest/jest/phpunit/pytest). Find existing test patterns (DB helpers, factory functions, mock conventions). If no manifest exists, infer runner from the target file extension. If still unknown, mark the file `FAILED` and backlog the environment issue. If Dimension 1 found an exemplar, stack is already implied — but confirm the runner from config.
8. **Build queue:**
   - **Explicit mode:** queue = user's target file(s)
   - **Auto mode with CodeSift:** use available CodeSift primitives to gather, at minimum:
     - dead or leaf production candidates
     - 90-day hotspots
     - whether each candidate export is referenced from test files
     - role/classification signals under `<source-root>/`
     Prefer one batched retrieval when the environment supports it; otherwise run equivalent read-only calls and merge the results.
     Dead/leaf symbols with 0 test refs = UNCOVERED. **Priority:** hub symbols first (many connections = failures cascade), then high-churn, then leaf.
     If any sub-query fails or returns empty, log degraded discovery and fall back to the non-CodeSift queue builder.
   - **Auto mode without CodeSift:** resolve `<source-root>` from the nearest manifest (`src/`, `app/`, `lib/`, else repo root), then glob for production files in that root using stack-appropriate extensions. Files without matching tests = UNCOVERED.
9. **Baseline test run:** execute test suite once per run, after the queue is known and before the queue loop starts, and record pre-existing failures. These are ignored in verification. **Skip Step 9 in `--dry-run`.** If the runner/config is unavailable, backlog one run-level environment issue and mark every queued file `FAILED` with `Blind Audit=skipped` and `Adversarial=not_run`, then stop.

**`--dry-run` mode:** after Step 8 builds the queue, run Step 1 (Analyze) for each file, print classification table, STOP. Never run Step 9 or any other shell command that would validate or mutate the suite.

---

## Per-File Loop

For each file in the queue, execute Steps 1, 2, 3, 3.5, 4, and 5 in order. Do NOT skip any step unless a later step explicitly defines a degraded terminal state such as `SKIPPED_REVIEW`. Do NOT proceed to the next file until every required checkpoint completes or is explicitly downgraded by the skill.

### Step 1: Analyze

The production file was already read and classified in Phase 0.5. **If a test file already exists, read it now.** Assess existing test quality:

- **No test file** → action: CREATE
- **Test file exists, quality OK** (behavioral assertions, no anti-patterns) → action: ADD TO (extend with missing coverage)
- **Test file exists, quality BAD** (fragile string tests, tautological oracles, security theatre, duplicated positives, structural tests that duplicate behavioral ones) → action: **REWRITE**. Fix the whole file, not just add tests. Net test count MAY decrease. Remove anti-patterns, consolidate with it.each, keep only behavioral tests.

**Duplicate test file detection:** Before locking the action, search sibling and legacy test trees for other test files that target the same production module (same import target, same basename, or same co-located `__tests__/` pattern).

- If 2+ active test files target the same production file, print `[DUPLICATE] Found {N} test files for {production-file}: {paths}`.
- Read every duplicate before deciding `ADD TO` vs `REWRITE`.
- Prefer the nearest co-located test file as the canonical file. If no co-located file exists, prefer the file with the strongest existing behavioral coverage.
- Do **not** silently create or extend a second overlapping test suite.
- If the duplicates materially overlap and cannot be safely consolidated within this single-file run, mark the file `FAILED`, backlog `duplicate-test-suite`, and stop instead of deepening the duplication.

**Do NOT add good tests on top of bad tests.** If existing tests are weak, fix them first. "ONE file, FULL pipeline" means the WHOLE test file, not just the gap you were sent to fix.

Rewrite scope is still single-file. Do not turn one target file into a broad anti-pattern cleanup campaign across unrelated tests; use `zuvo:fix-tests` for that.

**Barrel file detection:** If the file contains ONLY `export { X } from './sub-module'` lines (zero owned logic), it is a barrel/re-export file. Do NOT write delegation tests for it — write a coverage row immediately with `Status=SKIPPED_BARREL`, `Tests=0`, `Q Score=N/A`, `Blind Audit=skipped`, `Adversarial=not_run`, then expand the queue to the sub-modules it re-exports from. Print: `[BARREL] {file} is a re-export barrel — expanding to {N} sub-modules.`

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

If you find a bug: log it to `memory/backlog.md` with file:line and description.

- If the strongest honest regression test would be **red** against current production code, do NOT weaken the assertion just to satisfy Step 2.
- Instead: backlog the bug, mark the file `FAILED`, and hand off the production fix to `zuvo:debug` or `zuvo:build`.
- Only add a regression test in this skill when it can pass against the current production contract.

This prevents a deadlock between bug exposure and Step 2's green-test requirement.

Print: `[BUG-SCAN] Found {N} potential issues.` or `[BUG-SCAN] Clean.`

**With CodeSift:** gather outline, complexity, and call-chain context for the target file. Prefer one batched retrieval when supported; otherwise use equivalent discrete CodeSift calls and continue if any one dimension is unavailable.

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
3. **Apply mock rules** per the loaded `test-mock-safety-core.md` plus `test-mock-safety-{stack}.md` when that stack file was loaded.
4. **Write the test file.** Follow the contract and plan exactly.
   - When creating a new test file or fully rewriting one under this skill, prepend a generated marker using stack-native comment syntax:
     - JS/TS/PHP: `// Generated by zuvo:write-tests`
     - Python: `# Generated by zuvo:write-tests`
5. **Run tests:** `[test runner] [test file]`. All new tests must pass. Pre-existing failures ignored. Fix red tests before proceeding.

Red regression tests for known production bugs are not a valid terminal state for `write-tests`. If the truthful test stays red, backlog the bug and fail the file instead of weakening the assertion.

### Step 3: Verify

1. **Anti-tautology check:** grep test file for mock-return-echoed-in-assertion patterns. Verify every expected value is spec-derived, not implementation-derived. Any tautological oracle found = fix immediately.
   **Exception for THIN delegation:** When code type is THIN and the method body is a single `return delegateFunction(args)`, echo testing IS the behavioral test — the facade's contract is to forward unchanged. `expect(result).toBe(mockReturnValue)` combined with `CalledWith` is correct, not tautological. P-70 does NOT apply to pure delegation pass-through.
1b. **COMPONENT interaction gate:** For COMPONENT files, grep the production file for owned callback routing such as `onNext=`, `onBack=`, `onClick=`, `onSubmit=`, `onChange=`, or equivalent handler-selection branches. Then grep the test file for `fireEvent` or `userEvent`.
   - If the production file forwards callbacks and the test file has **0** interaction calls, STOP and add flow tests before self-eval.
   - For every distinct owned routing decision where the same child prop slot can receive different handlers by mode, type, or state, add at least one representative interaction test proving the correct handler fires and the competing handler does **not**.
   - Render-only assertions and label-only assertions do **not** satisfy Q3 or Q14 for callback-routing rows.
2. **Q1-Q19 self-eval** per `quality-gates.md`. Print scorecard with evidence:
   ```
   Self-eval: Q1=1 Q2=1 Q3=0 ... → [N]/19 [PASS|FIX|REWRITE]
   Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]
   ```
   Then print **critical-gate evidence** with one specific `test-file:line` citation per gate:
   - `Q7:` the error-path test proving exact type/message, or explicit `N/A — no production error paths`
   - `Q11:` the test(s) covering each owned production branch or routing path
   - `Q13:` the import line proving the real production module is under test
   - `Q15:` the assertion line proving content/value, not just count/shape
   - `Q17:` the assertion line plus expected-value source proving the oracle is not echoed from the mock
   If you cannot cite a specific `test-file:line` for a critical gate, score that gate `0`. Do **not** invent scores from memory or from general confidence.
   Any critical gate at 0: fix immediately and re-score.

Q-score is a quality gate, not an exhaustive coverage map. Step 3 validates test quality. Step 3.5 validates production behavior coverage.

### Step 3.5: Blind Coverage Audit

Read `../../shared/includes/blind-coverage-audit.md` now. This is the source of truth for the audit protocol.

Goal: run a **production-first** coverage audit before adversarial review. Strict contract-blind isolation is required for a passing blind audit. This is not another Q-score and must not reuse the writer's test contract.

**Reviewer routing is mandatory before audit dispatch.**

Resolve the writer hint using environment precedence:
- `CLAUDE_MODEL`
- `ZUVO_CODEX_MODEL`
- `CURSOR_AGENT_MODEL`
- `CURSOR_MODEL`
- `GEMINI_MODEL`
- `ANTIGRAVITY_MODEL`
- otherwise treat the writer hint as `unknown`

Run `../../scripts/reviewer-model-route.sh` with **no override flags** before selecting the blind-audit reviewer artifact. Enforce a **5s timeout**. Runtime callers must not `eval` resolver output.

Treat resolver output as valid only when stdout contains exactly one single-line `KEY=VALUE` entry for each required key:
- `platform`
- `writer_model`
- `writer_lane`
- `reviewer_lane`
- `reviewer_model`
- `routing_status`

Any missing key, duplicate key, unknown key, multi-line value, timeout, missing script, or non-zero exit status = `routing-failed`.

Print a routing note immediately after resolution, then repeat the same line in the final Step 3.5 output block:

```text
Reviewer routing: writer=<model>, reviewer=<model>, lane=<review-primary|review-alt|same-model-fallback>, status=<ok|same-model-fallback|unknown-writer-model|routing-failed>
```

Routing rules:
- `reviewer_lane=review-primary` and `routing_status=ok` -> use `blind-coverage-auditor`
- `reviewer_lane=review-alt` and `routing_status=ok` -> use `blind-coverage-auditor-alt`
- `reviewer_lane=same-model-fallback` or `routing_status=unknown-writer-model` -> use `blind-coverage-auditor`, record degraded routing explicitly, and never describe the audit as cross-model
- `routing_status=routing-failed` -> do not select an agent artifact from lane data; only a fresh subprocess may continue

If the resolver is missing, exits non-zero, times out, or emits malformed output, treat routing as degraded:
- `Reviewer routing: writer=<writer-hint-or-unknown>, reviewer=unknown, lane=same-model-fallback, status=routing-failed`
- continue only if strict isolated execution is still available
- never invent a reviewer mapping inline

**Execution paths:**

- **Required:** isolated read-only `blind-coverage-auditor` or `blind-coverage-auditor-alt`, chosen from the resolver output above, or a fresh subprocess that receives only the files below

Strict isolated execution receives only:
- `../../shared/includes/blind-coverage-audit.md`
- production file
- test file
- optional repo identifier

Do not use CodeSift in strict mode. If isolated execution is unavailable or fails, do NOT substitute an inline same-run audit. Mark the file `FAILED`, persist `Blind Audit=skipped`, set `Adversarial=blocked`, and stop after backlog persistence.

**Audit order:**

1. Read the production file first and enumerate owned behaviors.
2. Classify each row as owned vs delegated.
3. Read the test file second and map evidence.
4. Assign one coverage state per row: `FULL | PARTIAL | NONE | STRUCTURAL_ONLY | N/A`
5. Issue one verdict: `CLEAN | FIX | REWRITE`
6. Name exactly one highest-value missing test.

Thin delegators and wrappers are audited on forwarding contract only. Do NOT demand downstream implementation tests. Barrels remain out of scope. Accessibility fallbacks, including nodes such as `role="status"`, are owned behavior when this module renders them.

**Pass budget:** max 2 blind-audit passes per file.

- **Pass 1:** audit the current test file.
- **If verdict = FIX:** patch tests, re-run the target test file, then rerun Step 3.5 once.
- **If verdict = REWRITE:** rewrite the test file from Step 2, rerun Step 3, then rerun Step 3.5 once.
- **If verdict remains FIX or REWRITE after pass 2:** mark the file `FAILED`, backlog the findings, and do NOT proceed to Step 4.

**Blind-audit state machine:**

| Blind-audit result | Step 4 transition | `coverage.md` Blind Audit value | Resume behavior |
|--------------------|-------------------|---------------------------------|-----------------|
| `CLEAN` via strict path | Proceed to Step 4 | `clean:strict` | If adversarial status is missing, resume at Step 4 |
| `FIX` on pass 1 | Block Step 4; patch tests and rerun once | `fix:<n>` | Resume at Step 3.5 |
| `REWRITE` on pass 1 | Block Step 4; rewrite from Step 2, then rerun Step 3 + 3.5 once | `rewrite` | Resume at Step 2 |
| `FIX` or `REWRITE` on pass 2 | Do NOT run Step 4; mark file `FAILED` and set `Adversarial=blocked` | `fix:<n>` or `rewrite` | Skip after backlog persistence |
| Strict audit unavailable or inputs unreadable | Do NOT run Step 4; mark file `FAILED` and set `Adversarial=blocked` | `skipped` | Skip after backlog persistence |

Emit the exact table schema from `blind-coverage-audit.md`. Summary-only prose is not enough.

Print:
```
Reviewer routing: writer=<model>, reviewer=<model>, lane=<review-primary|review-alt|same-model-fallback>, status=<ok|same-model-fallback|unknown-writer-model|routing-failed>
Audit mode: strict
Coverage verdict: [CLEAN|FIX|REWRITE]
INVENTORY COMPLETE: [N] rows
| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |
Prioritized findings: [N or none]
Highest-value missing test: [one concrete test]
```

### Step 4: Adversarial Review (iterative, complexity-tiered)

Enter Step 4 only when Step 3.5 returned `Audit mode: strict` and `Coverage verdict: CLEAN`.

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

**Adversarial routing priority:**

1. **Primary path:** external cross-provider `adversarial-review --rotate`
2. **Fallback-local path:** same environment, different-from-writer read-only agent selected via `../../scripts/reviewer-model-route.sh`
3. **Final degraded state:** `SKIPPED_REVIEW`

If the primary path is missing, exits non-zero, or every provider returns empty:
- run `../../scripts/reviewer-model-route.sh` with the same 5s timeout and parser rules used in Step 3.5
- print:
  ```text
  Adversarial routing: path=fallback-local, writer=<model>, reviewer=<model>, lane=<review-primary|review-alt>, status=<ok|same-model-fallback|unknown-writer-model|routing-failed>
  ```
- route `review-primary` -> `adversarial-test-reviewer`
- route `review-alt` -> `adversarial-test-reviewer-alt`
- require `routing_status=ok`
- if routing resolves to `same-model-fallback`, `unknown-writer-model`, or `routing-failed`, do **NOT** run local adversarial fallback; mark file `SKIPPED_REVIEW`

Fallback-local review is a degraded second opinion. It is valid only when the fallback reviewer model differs from the writer model. Never label it as cross-provider review.

**Pass sequence with structured context (prevents repetition):**

```
Pass 1 (primary path):
  adversarial-review --rotate --mode test --context "..." --files "<prod> <test>"
  Record provider identity only if the script exposes it reliably.
  → fix CRITICAL/WARNING → re-run tests

Pass 2 (primary path):
  adversarial-review --rotate [--exclude <pass-1-provider> if known] --mode test \
    --context "... FIXED: [...]. REJECTED: [...]. KNOWN: [...]." \
    --files "<prod> <test>"
  → fix findings → re-run tests

Pass 3 (COMPLEX only, if pass 2 had CRITICAL):
  adversarial-review --rotate [--exclude <pass-2-provider> if known] --mode test \
    --context "..." --files "<prod> <test>"

Fallback-local path (only if the primary path never produced a successful provider result):
  dispatch `adversarial-test-reviewer` or `adversarial-test-reviewer-alt`
    with the production file, test file, stack context, and current FIXED/REJECTED/KNOWN notes
  use the same pass budget and fix policy as above
  persist the result as `clean:fallback-local` or `<n> findings:fallback-local`
```

**Context rules:**
- FIXED findings must NOT be re-raised. If reviewer repeats a fixed finding, ignore it.
- REJECTED findings have a **severity cap**: `REJECTED: [finding] — max re-raise: INFO`. If reviewer escalates a rejected finding above the cap (e.g. INFO → CRITICAL), auto-ignore. This prevents adversarial from overriding conscious scope decisions.
- Before rejecting any CRITICAL/WARNING finding, restate the **attack vector** in one sentence and verify that your rejection defeats that attack vector, not just the reviewer's suggested fix.
- If the suggested fix is wrong but the attack vector still applies, the finding is **not** rejected. Either fix it another way or carry it forward as `KNOWN` / backlog.
- Each pass adds its own fixes/rejections to the context for the next pass.
- Early exit: 0 new findings (not counting repeats of FIXED/REJECTED).

**Stub fidelity rule for ORCHESTRATOR:** Route module stubs MUST use `all()` (catch-all). Testing HTTP methods (GET vs POST) is the responsibility of route module tests, not orchestrator tests. If adversarial flags "stubs don't verify HTTP methods" — REJECT with "scope mismatch, route module responsibility".

If `adversarial-review` is not found: check `../../scripts/adversarial-review.sh`. If missing entirely, attempt fallback-local routing. If fallback-local is unavailable or not safely different-from-writer, mark file `SKIPPED_REVIEW`, record a degraded completion note, and proceed.

**Fix policy per pass:**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING (<10 lines)** | Fix immediately. |
| **WARNING (>10 lines)** | Add to backlog with file:line. |
| **INFO** | Known concerns (max 3). |
| **0 findings** | Early exit — stop passes, file is clean. |
| **After final pass with unresolved CRITICAL** | Mark file **FAILED** in coverage.md. Backlog findings. |
| **Provider unavailable on all passes and fallback-local unavailable** | Mark file **SKIPPED_REVIEW** in coverage.md. |

### Step 5: Log

Update `memory/coverage.md`:
```
| File | Status | Tests | Q Score | Blind Audit | Adversarial | Date |
```

Statuses: `PASS`, `FAILED`, `SKIPPED_REVIEW`, `SKIPPED_BARREL`
Blind Audit values: `clean:strict`, `fix:<n>`, `rewrite`, `skipped`
Adversarial values: `clean`, `clean:fallback-local`, `<n> findings`, `<n> findings:fallback-local`, `skipped`, `blocked`, `not_run`

`SKIPPED_REVIEW` is a degraded terminal state, not a clean pass. Never silently collapse it into `PASS`.
Rows that never enter Step 4 must persist `Adversarial=blocked` or `Adversarial=not_run`; never leave the column empty.

Persist `Q Score` as a durable value, not prose memory: `<score>/19 (Q7=?,Q11=?,Q13=?,Q15=?,Q17=?)`.

Print per-file summary: `[status] [file] — [N] tests, Q [N]/19, blind audit: [clean:strict|fix:<n>|rewrite|skipped], adversarial: [clean|clean:fallback-local|N findings|N findings:fallback-local|skipped|blocked|not_run]`

Do NOT treat a file as complete unless both `Blind Audit` and `Adversarial` columns are populated.

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
Blind audit:   [N] clean, [M] failed/rewrite, [K] skipped
Validation:    [full-suite|scoped:touched-tests]
Failures:      pre-existing: [N], new in scope: 0
FAILED files:  [list or "none"]
SKIPPED_REVIEW: [list or "none"]
SKIPPED_BARREL: [list or "none"]
Run: <ISO-8601-Z>	write-tests	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```

Append `Run:` line to log file per `run-logger.md`.

Run one final full-suite validation, or explicitly scope the final failure count to touched test files only before printing `new in scope: 0`.

**Do NOT print WRITE-TESTS COMPLETE if any file is missing `Status`, `Blind Audit`, or `Adversarial` in coverage.md.**

---

## Resume / Crash Recovery

On start, read `memory/coverage.md`. If the file uses the old pre-blind-audit schema, normalize the row once by adding empty `Blind Audit` and `Adversarial` cells with note `legacy-pre-blind-audit`, then resume from Step 3.5 before Step 4.

| Status | Blind Audit | Adversarial | Resume action |
|--------|-------------|-------------|---------------|
| PASS | `clean:strict` | present | Skip |
| FAILED | `fix:<n>` or `rewrite` or `skipped` | any | Skip (already backlogged) |
| SKIPPED_REVIEW | `clean:strict` | `skipped` | Re-process Step 4 only |
| SKIPPED_BARREL | `skipped` | `not_run` | Skip |
| status missing or non-terminal legacy row | `fix:<n>` | missing or stale | Re-process Step 3.5 |
| status missing or non-terminal legacy row | `rewrite` | missing or stale | Re-process from Step 2, then Step 3 + 3.5 |
| status missing or non-terminal legacy row | `skipped` | missing or stale | Re-process Step 3.5 only if inputs are now readable |
| (absent) | - | - | Process from Step 1 |

If a test file exists on disk but file is absent from coverage.md → partial run. Check if file was auto-generated (contains stack-native marker `Generated by zuvo:write-tests`, e.g. `// ...` or `# ...`). If yes, delete and re-process from Step 1. If no (pre-existing/manual test), assess quality in Step 1 and choose ADD TO or REWRITE.

Auto mode: re-run CodeSift discovery to rebuild priority queue (queue order not persisted).

---

## Principles

1. Read production code before planning tests. Every assertion traces to real behavior.
2. Test depth matches complexity. A 25-line wrapper does not need 30 edge-case tests.
3. Test what the code OWNS, mock what it DELEGATES.
4. ONE file, FULL pipeline. No batching of files or pipeline steps. Batched read-only discovery queries are allowed.
5. Blind coverage audit and adversarial review are separate gates. Step 4 never runs until Step 3.5 is clean.
