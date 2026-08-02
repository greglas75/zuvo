---
name: write-tests
description: >
  Write tests for existing production code. Processes ONE file at a time
  through a full pipeline: analyze, inventory (frozen BEFORE writing), write,
  executable coverage gate, verify, blind coverage audit, adversarial review,
  log. Uses CodeSift for discovery and analysis when available. Modes: [path]
  (specific target), auto (discover and loop until done), --dry-run (plan only;
  skips suite verification).
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols           # find production functions to test
    - get_symbol
    - get_symbols
    - get_file_outline
    - get_context_bundle       # symbol + neighbors for behavioral coverage
    - find_references          # discover real usage patterns to mirror
    - search_text
    - search_patterns          # known testable shapes (controllers, services)
    - get_test_fixtures        # pytest fixture graph
  by_stack:
    typescript: [get_type_info, resolve_constant_value]
    javascript: []
    python: [python_audit, analyze_async_correctness, resolve_constant_value]
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

# zuvo:write-tests — Single-File Test Pipeline

Generate high-quality tests for production code. Each file goes through the full pipeline individually — no batching of files or pipeline steps, no skipping verification in normal mode, no skipping the coverage gate or audit.

The pipeline's spine is **inventory-first + executable proof**: the public
surface is enumerated and FROZEN before the first test is written, and the only
authority on coverage completeness is `scripts/test-coverage-gate.py` — a
program, not the writer's own claim.

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
  1. ../../shared/includes/codesift-setup.md            -- [READ | MISSING -> DEGRADED]
  2. ../../shared/includes/no-pause-protocol.md         -- [READ | MISSING -> WARN] (HARD: no mid-file pauses in batch/auto mode)
  3. ../../shared/includes/test-reviewer-routing.md     -- [READ | MISSING -> WARN] (preflight + all reviewer routing)
  4. ../../shared/includes/test-inventory-protocol.md   -- [READ | MISSING -> BLOCKED] (inventory-before-writing spine)
  5. ../../shared/includes/coverage-manifest-schema.md  -- [READ | MISSING -> BLOCKED] (manifest + validator contract)
```

If `codesift-setup.md` is missing, print `[CONTEXT] codesift-setup missing — assuming CodeSift unavailable and continuing in degraded mode.` If `test-inventory-protocol.md` or `coverage-manifest-schema.md` is missing, the executable gate cannot be honored — stop the run with a loud include-integrity error rather than degrading to prose-only gating.

### PHASE 0.5 — Classify (read production file, determine loading tier)

Read the production file fully, then read `../../shared/includes/test-code-types-core.md` and classify from that file's canonical table. Do NOT classify from memory. (Phase 1 lists the same file — this Phase 0.5 read IS that load; do not read it twice.)

- **Code type:** VALIDATOR / SERVICE / CONTROLLER / HOOK / PURE / COMPONENT / GUARD / API-CALL / ORCHESTRATOR / STATE-MACHINE / ORM-DB
- **Complexity:** THIN / STANDARD / COMPLEX
- **Testability:** UNIT_MOCKABLE / UNIT_REFLECTION / NEEDS_INTEGRATION / MIXED

```
IF code_type IN (PURE, VALIDATOR) AND complexity == THIN       → LIGHT
IF code_type IN (PURE, VALIDATOR) AND complexity == STANDARD   → STANDARD
IF code_type IN (STATE-MACHINE) AND complexity == THIN         → LIGHT
IF code_type IN (COMPONENT, HOOK)                              → COMPONENT
IF code_type IN (CONTROLLER, ORCHESTRATOR)                     → HEAVY
IF complexity == COMPLEX                                       → HEAVY
IF module mixes code types                                     → STANDARD (HEAVY if any unit is COMPLEX)
ELSE                                                           → STANDARD
```

Ambiguous → STANDARD. Print: `[CLASSIFIED] {file}: {code_type} {complexity} → tier {TIER}`

### PHASE 1 — Conditional Load (based on tier + detected stack)

Load ONLY the includes matching tier AND stack. Print READ/SKIP per file. If an include is missing: print `[PHASE1] MISSING: <file> — continuing with degraded rules`, keep loading, then print `loaded=<N>/<M>`; if under half loaded, print `[WARN] Low include availability — coverage planning and Q-score confidence are reduced. Do not overclaim clean states.`

| Include | LIGHT | STANDARD | HEAVY | COMPONENT |
|---------|-------|----------|-------|-----------|
| `../../shared/includes/test-contract.md` | Full | Full | Full | Full |
| `../../shared/includes/test-blocklist.md` (incl. typed mock gate) | Full | Full | Full | Full |
| `../../shared/includes/quality-gates.md` | Q1-Q25 only* | Q1-Q25 only* | Q1-Q25 only* | Q1-Q25 only* |
| `../../rules/testing.md` | Full | Full | Full | Full |
| `../../shared/includes/test-mock-safety-core.md` | Full | Full | Full | Full |
| `../../shared/includes/test-code-types-core.md` | Full | Full | Full | Full |
| `../../shared/includes/test-bugfix-protocol.md` | Full | Full | Full | Full |
| `test-mock-safety-{stack}.md` (js/php) | **SKIP** | Full | Full | Full‡ |
| `test-code-types-{stack}.md` (js/php) | **SKIP** | Full | Full | Full‡ |
| `../../shared/includes/test-edge-cases.md` | **SKIP** | Full | Full | Full |
| `../../shared/includes/test-mutation-probes.md` | **SKIP**† | Full | Full | Full |

\* **quality-gates.md:** Read ONLY `## Q1-Q25: Test Quality Gates` to end of file. Skip CQ1-CQ40.
† LIGHT loads it only when the file has an error fallback (probe class 2).
‡ COMPONENT loads the stack files too (fixed 2026-08-01): `test-code-types-core.md`'s
COMPONENT Callback Routing Guard explicitly defers its framework example to
`test-code-types-js.md` (Dispatch/Router template, Lazy/Suspense caveat, Time-Dependent
fake-timer table) — skipping them left that pointer dangling for the one tier that needs it.

**Stack detection:** nearest manifest — `package.json` => JS/TS, `composer.json` => PHP, `pyproject.toml` => Python (core-only mode). Ties: `package.json` > `composer.json` > `pyproject.toml`; print the conflict decision. Target-file extension beats the manifest winner. Load at most one stack-specific include family.

### DEFERRED — Load after queue empty (Completion only, once per run)

```
  D1. ../../shared/includes/run-logger.md           -- [READ at completion]
  D2. ../../shared/includes/retrospective.md        -- [READ at completion]
  D3. ../../shared/includes/knowledge-curate.md     -- [READ at completion]
  D4. ../../shared/includes/test-quality-gate.md    -- [READ at completion] (final zuvo:test-audit gate → tier A)
```

---

## Phase 0: Bootstrap + Preflight (once per run), Classify (per file)

1. **CodeSift setup** per `codesift-setup.md`. Note repo identifier.
2. **Resolve `$ZUVO_BASE`** per `test-reviewer-routing.md` (absolute paths for every script call).
3. **Reviewer preflight (REQUIRED, before any test is written):** run `bash "$ZUVO_BASE/scripts/reviewer-preflight.sh"` and act on `preflight_status` per the table in `test-reviewer-routing.md`. On `no-provider`/`canary-failed`: print `review infrastructure unavailable` NOW — the whole run is `DRAFT/BLOCKED_INFRA` from the start; tests may still be written for their standalone value, but no file may be reported `PASS` and the completion block must carry the BLOCKED_INFRA list. This replaces discovering a dead reviewer after the pipeline already spent its budget.
4. **Read production file. Detect stack. Classify. Load includes** per PHASE 0.5 / PHASE 1 above.
5. **Dynamic context retrieval (when CodeSift available)** — dimensions by tier: LIGHT → D1; STANDARD → D1 + D2/D3 (conditional) + D4; HEAVY → D1-D4; COMPONENT → D1 + D4. Skip any dimension that times out; partial context beats none.
   - **D1 exemplar test (all tiers):** find an existing test for this module (`find_references` on the main export → `*.test.*`/`*.spec.*`; fallback `search_text` for `describe`/`extends TestCase`/`class Test...` per stack). Read it fully — it defines mock style, structure, setup, matcher and cleanup conventions. Print `[CONTEXT] Exemplar: {path}` or `— none, using generic patterns`.
   - **D2 import mocks (STANDARD+; skip if exemplar is same-module):** for ≤5 target imports, `search_text` for existing `vi.mock`/`jest.mock`/`createMock`/`mock.patch` patterns in project tests.
   - **D3 test setup (STANDARD+; skip if CLAUDE.md or exemplar covers it):** `search_text` for `setupFiles`/`_bootstrap`/`conftest` config; read setup outlines.
   - **D4 hub signatures (STANDARD+/COMPONENT):** `search_symbols` (bare names, `detail_level: "compact"`, `include_source: true`, `token_budget: 800`) for the target's imported utilities. Never `get_symbols()` on bare names.
   - On repo/index errors run the `codesift-setup.md` recovery loop once; on `Transport closed` abandon CodeSift for the rest of the run. Without CodeSift: skip all dimensions, print `[CONTEXT] CodeSift unavailable — using legacy detection.`
6. **Test runner refinement:** read the nearest manifest/config; detect runner (vitest/jest/phpunit/pytest) and existing test conventions. No manifest → infer from extension; still unknown → mark file `FAILED`, backlog the environment issue. For JS/TS COMPONENT/HOOK targets check DOM-matcher registration and cleanup globality; reuse the exemplar's local pattern when global setup is absent.
7. **Build queue:** explicit mode = user's targets. Auto mode with CodeSift: gather dead/leaf candidates, 90-day hotspots, test-reference counts, role signals; 0 test refs = UNCOVERED; priority hub > high-churn > leaf; degraded discovery falls back to the manifest-root glob. Auto mode without CodeSift: glob production files under the source root; files without matching tests = UNCOVERED.
8. **Baseline test run** (once per run, after queue, before loop): record pre-existing failures — they are ignored in verification. **Skip in `--dry-run`.** Runner/config unavailable → backlog one run-level environment issue, mark every queued file `FAILED` (`Blind Audit=skipped`, `Adversarial=not_run`), stop.
   - **Schema-drift pre-probe** (only when queue has an ORM-DB target or DB test helper): run one seed/schema probe; `column/relation/table does not exist` = run-level ENV blocker — backlog, mark every DB-backed file `FAILED`, stop. Skip in `--dry-run`.

**`--dry-run`:** after the queue is built, run Step 1 (Analyze) per file, print the classification table, STOP. Never run suite-mutating commands.

---

## Per-File Loop

Execute Steps 1 → 1.5 → 1.6 → 1.7 → 2 → 2.5 → 3 → 3.2 → 3.3 → 3.5 → 4 → (4.5) → 5 in order. Do NOT skip a step unless a later step explicitly defines a degraded terminal state. Do NOT proceed to the next file until every checkpoint completes or is explicitly downgraded.

### Step 1: Analyze

Production file already read/classified. **If a test file exists, read it now** and pick the action:

- **No test file** → CREATE
- **Exists, quality OK** (behavioral assertions, no anti-patterns) → ADD TO
- **Exists, quality BAD** (fragile string tests, tautological oracles, security theatre, duplicated positives, structural duplicates) → **REWRITE** the whole file. Net test count MAY decrease. **Do NOT add good tests on top of bad tests.**

**Duplicate test files:** search sibling/legacy trees for other test files targeting the same module. 2+ active → print `[DUPLICATE] ...`, read all, prefer the co-located file as canonical; never silently extend a second overlapping suite. Unconsolidatable overlap → `FAILED` + backlog `duplicate-test-suite`.

**Barrel file** (only `export { X } from ...` lines): do NOT write delegation tests. Record `Status=SKIPPED_BARREL`, `Tests=0`, `Q Score=N/A`, `Blind Audit=skipped`, `Adversarial=not_run`; expand the queue to its sub-modules. Print `[BARREL] {file} — expanding to {N} sub-modules.`

**With an exemplar (D1):** extract and follow its cleanup pattern, matcher library, async pattern, mock factory style, and import conventions. Do NOT invent new patterns. D2 mock patterns feed MOCK INVENTORY; D4 signatures feed assertion planning.

Rewrite scope stays single-file — broad anti-pattern campaigns belong to `zuvo:fix-tests`.

### Step 1.5: Bug Scan (before planning tests)

Scan the production code for bugs: missing error handling, logic errors (wrong operator, off-by-one, inverted condition), security gaps, unhandled edge cases. Every confirmed find is a **fix-in-run candidate for Step 4.5** per `test-bugfix-protocol.md` — never a silent backlog row. If the strongest honest test would be RED, write a characterization test now and fix in Step 4.5 (never weaken the assertion).

Print: `[BUG-SCAN] Found {N} potential issues.` or `[BUG-SCAN] Clean.`

### Step 1.6: Production Surface Inventory (FROZEN before writing)

Follow `test-inventory-protocol.md` Step 1.6 exactly:

1. Run the independent extractor: `python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" extract --production <file>` — its symbol list is the floor; add rows for surface it cannot see (routes, indirect callers), never remove one it found.
2. Add rows per symbol: entry + every owned branch + every explicit error path + owned side effects. Honest `owned`/`delegated` classification.
3. Write the manifest to `$ZUVO_DIR/contracts/<basename>.coverage.json` (`status: "inventory"`, current sha256, NO coverage claims).
4. Print `INVENTORY FROZEN` with the N/N projected metrics. **For COMPLEX files these N/N metrics — public methods, owned rows, error paths — are the ONLY progress numbers; never present a test count as progress.**

**Split rule (mandatory):** >15 public entry points OR >40 owned rows OR >800 production LOC OR >800 projected test LOC → split into sibling specs by responsibility per the protocol; one manifest aggregates all siblings.

### Step 1.7: Inventory Validation

```bash
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" validate \
  --manifest "$ZUVO_DIR/contracts/<basename>.coverage.json" \
  --phase inventory --repo-root "$(git rev-parse --show-toplevel)"
```

exit 0 → frozen, proceed. exit 1 → extractor found symbols the inventory missed: add them, rerun. **Never start writing tests over a failing freeze.** exit 3 → degraded extraction: record `BLOCKED_DEGRADED` evidence quality for the rest of the file (see `coverage-manifest-schema.md`). After this point the symbol list is immutable for the run; any production edit invalidates the manifest (hash) and forces a re-freeze.

### Step 2: Write

1. **Fill the test contract** per `test-contract.md` (BRANCHES, ERROR PATHS, EXPECTED VALUES, MOCK INVENTORY, MUTATION TARGETS, TEST OUTLINE) — derived from the frozen inventory, not re-derived from scratch. 3+ methods sharing a control-flow pattern → per-pattern mode. Do not print the full contract; show only branch table + outline + planned metrics.
2. **Check `test-blocklist.md`** — including the typed mock gate (no `Record<string, Mock>` service mocks, no `as never`, no broad `as any`, no unused mocks, no `expect.anything()` on domain arguments; typed `Pick<Service, ...>`/`MockedMethods<T, K>` instead).
3. **Apply mock rules** per loaded `test-mock-safety-*` includes.
4. **Write the test file with `Write`** (full file, atomic — NEVER sequential `Edit` for creation/rewrite; linters can rewrite between edits). `Edit` only for targeted single-hunk changes after all tests pass. Prepend the stack-native marker comment `Generated by zuvo:write-tests`. When splitting, write and green one sibling spec at a time.
5. **Extension pre-flight (JS/TS):** verify the test extension matches the runner's `include` pattern (`.spec` vs `.test`); rename BEFORE the first run — wrong extensions compile but never run in CI.
6. **Run the target tests.** All new tests must pass; pre-existing failures ignored. On truncated/unclear output or 5+ failures switch to structured diagnostics (isolate one failing test; JSON/verbose reporter; fix the first concrete root cause before mass-editing). Testing-library specifics: missing DOM matcher → local import only when global setup lacks it; repeated `Found multiple elements` → local `afterEach(cleanup)` only when cleanup is not global.

Red truthful tests for production bugs are not a terminal state: characterization-now + fix-in-4.5, or out-of-scope escalation per `test-bugfix-protocol.md`. Backlogging a fixable bug is not a valid exit.

**PURE optimization (LIGHT):** contract may skip MOCK INVENTORY if only Logger; keep BRANCHES, ERROR PATHS, EXPECTED VALUES. **COMPONENT:** follow exemplar cleanup/matcher/async patterns. Neither skips adversarial.

### Step 2.5: LOCAL COVERAGE GATE (executable)

The gate is a program, not a checklist. Map the written tests into the FROZEN manifest per `test-inventory-protocol.md` Step 2.5: fill each row's `coverage` + `test-file:line` evidence, set `status: "final"`, record `quality_gates` (Q7/Q11 from the upcoming self-eval — run Step 3's critical-gate scoring for these two now), then run:

```bash
python3 "$ZUVO_BASE/scripts/test-coverage-gate.py" validate \
  --manifest "$ZUVO_DIR/contracts/<basename>.coverage.json" \
  --phase final --repo-root "$(git rev-parse --show-toplevel)"
```

The validator independently re-extracts every public entry point from the production AST and checks: no missing symbols, every owned row `FULL` or excused with a note, every evidence entry an existing test-file:line inside a real test — or the durable form `test-file::exact test name`, which survives formatters and is PREFERRED (convert a line-based manifest once with `test-coverage-gate.py refresh --manifest <m>`) — no duplicate/empty evidence, production hash unchanged, `Q7=1 and Q11=1`. Its printed block — including `Uncovered owned rows: 0` — is the ONLY acceptable pass evidence; paste it, never paraphrase it.

```
LOCAL COVERAGE GATE
<validator output block verbatim>
Public entry points: [N]/[N] FULL
Uncovered owned rows: 0
```

- exit 0 → proceed to Step 3.
- exit 1 → add/strengthen tests for every printed violation, rerun the target tests, rerun the validator. A validator FAIL is never closed by editing manifest rows into excused states.
- exit 3 → all checks green but extraction was textual: record `BLOCKED_DEGRADED` evidence quality; continue only with a strict blind audit.

If a row cannot be closed because required infrastructure or a cross-module contract is unavailable: persist `Status=BLOCKED_INCOMPLETE` with the uncovered rows + reason; do not continue to Step 3.5, do not mark `PASS`, do not print `WRITE-TESTS COMPLETE`. Lack of time, a large method count, or an already-high test count are not valid waivers.

### Step 3: Verify (quality, not coverage — coverage was Step 2.5)

**Context resume guard:** after a compaction resume, prior-session claims ("clean blind audit") are UNVERIFIABLE — only tool output in the current window counts; re-run Steps 3.5/4 for the current file pair.

1. **Anti-tautology check:** grep for mock-return-echoed-in-assertion; every expected value spec-derived. Exception: THIN pure delegation — echo + `CalledWith` IS the behavioral test (P-70 does not apply).
1b. **COMPONENT interaction gate:** production forwards callbacks + test has 0 `fireEvent`/`userEvent` → STOP, add flow tests. Every owned handler-routing decision gets ≥1 interaction test proving the right handler fires and the competing one does not. Render/label-only assertions never satisfy Q3/Q14 for routing rows.
2. **Q1-Q25 self-eval** per `quality-gates.md`, with per-gate `test-file:line` evidence for the critical gates:
   ```
   Self-eval: Q1=1 Q2=1 ... → [N]/[applicable] [PASS|FIX|REWRITE]
   Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]
   ```
   `Q7` error-path proof (or evidence-backed `N/A`), `Q11` per-branch tests, `Q13` real-module import line, `Q15` content-not-shape assertion, `Q17` non-echoed oracle. No citable line = score 0. Step 3 passes only with Q7=1, Q11=1, Q13=1, Q15=1, Q17=1 — a zero critical gate is `BLOCKED_INCOMPLETE`, never a publishable partial result. Sync the final Q7/Q11 values back into the manifest and rerun the Step 2.5 validator if they changed.

### Step 3.2: Target Coverage (when the runner supports it)

Run coverage scoped to the production file only (e.g. `vitest run <spec> --coverage.include=<production-file>`, `pytest --cov=<module> <test-file>`, phpunit `--coverage-filter`). Thresholds:

```
statements >= 85%   branches >= 75%   functions >= 90%   lines >= 85%
```

Record the four numbers. Below threshold → find the uncovered lines, close them (or add excused manifest rows with notes), rerun. For COMPLEX files the binding rule remains zero uncovered public functions — the percentages supplement, never replace, the Step 2.5 gate. Runner has no coverage support → print `[COVERAGE] runner lacks coverage support — skipped` (not a failure).

### Step 3.3: Mutation Probes

Per `test-mutation-probes.md`: 3 probes (STANDARD) / 5 (HEAVY-COMPLEX, ≥1 per behavior group), byte-restore protocol, scoped runs. Every probe must be killed; a surviving probe is a coverage gap — close it and re-probe. Print the `MUTATION PROBES: [N]/[N] killed` table. Post-restore sha256 must equal the manifest hash.

### Step 3.5: Blind Coverage Audit

Read `../../shared/includes/blind-coverage-audit.md` now — it is the audit protocol. Routing, agent selection, degraded rules, and the fresh-subprocess wrapper are defined in `test-reviewer-routing.md` (already loaded); follow it exactly and print the `Reviewer routing:` line after resolution and again in the final block.

Strict contract-blind isolation is required for a passing audit. The audit is production-first (inventory → ownership → evidence mapping → verdict `CLEAN|FIX|REWRITE` → one highest-value missing test). Thin delegators audited on forwarding contract only; barrels out of scope; rendered a11y fallbacks are owned behavior.

**Pass budget: max 2.** Pass 1 audits current files; `FIX` → patch tests, rerun tests, rerun audit once; `REWRITE` → rewrite from Step 2, rerun Step 3 chain, audit once. Still FIX/REWRITE after pass 2 → `FAILED`, backlog, no Step 4.

| Blind-audit result | Step 4 | `coverage.md` value | Resume |
|--------------------|--------|---------------------|--------|
| `CLEAN` strict (routing ok, reviewer ≠ writer) | Proceed | `clean:strict` | resume at Step 4 if adversarial missing |
| `CLEAN` degraded routing | Proceed | `clean:degraded` | adversarial compensates |
| `FIX` pass 1 | Block; patch + rerun once | `fix:<n>` | resume at Step 3.5 |
| `REWRITE` pass 1 | Block; rewrite, Step 3 chain, rerun once | `rewrite` | resume at Step 2 |
| `FIX`/`REWRITE` pass 2 | No Step 4; `FAILED`, `Adversarial=blocked` | `fix:<n>`/`rewrite` | skip after backlog |
| Wrapper timeout/missing/invalid | No Step 4; `BLOCKED_INFRA` (tests may be fine) | `skipped` + failure cause | skip after backlog |
| Strict unavailable / inputs unreadable | No Step 4; `BLOCKED_INFRA`, `Adversarial=blocked` | `skipped` | skip after backlog |

**Freshness guard (semantic):** before each pass record the production file's sha256 AND the test file's normalized hash (`test-coverage-gate.py normhash --file <test>`). A result is valid only for that exact pair. A later edit whose normhash is UNCHANGED (comments/whitespace/line-wrap/trailing-comma only — the program proves it) does NOT invalidate a CLEAN; any production sha change or test normhash change does. Never widen this by judgment — the normhash decides, not intent. Emit the exact table schema from `blind-coverage-audit.md`; summary prose is not enough.

### Step 4: Adversarial Review (iterative, complexity-tiered)

Enter only when Step 3.5 returned `Audit mode: strict` + `Coverage verdict: CLEAN`. Sequential passes, one RANDOM provider per pass (`--rotate`), early exit on 0 findings.

| Complexity | Max passes |
|-----------|-----------|
| THIN | 1 |
| STANDARD | 2 |
| COMPLEX | 2 + 3rd ONLY if pass 2 found high-confidence CRITICAL |

```bash
adversarial-review --rotate --mode test \
  --context "STACK: [language+version / test-framework+version]. Code type: [type] [complexity] [testability]. Q-GATES: Q7..Q17. [pass 2+: FIXED/REJECTED/KNOWN lists]" \
  --files "<abs-production> <abs-test>" > zuvo/review.txt 2>&1
```

- **STACK is mandatory** (prevents JS-assumption false positives on PHP/Python).
- **Absolute paths only.** Read the FULL captured output — never `tail`/`head` as the triage source (a pass-2 CRITICAL was lost to `tail -60`).
- Pass 2+: `--exclude <prior-provider>` when known; context carries FIXED (never re-raised), REJECTED (severity-capped: `max re-raise: INFO`; escalation above cap auto-ignored), KNOWN.
- Before rejecting a CRITICAL/WARNING: restate the attack vector in one sentence and verify the rejection defeats the VECTOR, not just the suggested fix; otherwise fix another way or carry as KNOWN.
- ORCHESTRATOR stub fidelity: route stubs use `all()`; "stubs don't verify HTTP methods" → REJECT (route-module responsibility).
- Primary path missing/empty → fallback-local per `test-reviewer-routing.md`; unroutable → `SKIPPED_REVIEW`.

| Finding | Action |
|---------|--------|
| CRITICAL | Fix immediately, re-run tests |
| WARNING <10 lines | Fix immediately |
| WARNING >10 lines | Backlog with file:line |
| INFO on security-context file (lines 1-5 contain `CQ4`,`CQ5`,`GDPR`,`PII`,`auth`,`token`,`password`,`secret`) | Treat as WARNING; rejection requires backlog entry |
| INFO otherwise | Known concerns (max 3), rejectable with justification |
| 0 findings | Early exit — clean |
| Unresolved CRITICAL after final pass | `FAILED` + backlog |
| No provider on all passes + no fallback-local | `SKIPPED_REVIEW` |

High-confidence production bugs found here: verify against source, then route to Step 4.5 — fix in-run, never `FAILED`-and-hand-off for an in-scope fix.

### Step 4.5: Fix surfaced production bugs (in-run)

Follow `test-bugfix-protocol.md`: fix-scope (not severity) decides fix-now-vs-escalate; stacked commits (characterization → fix + flipped regression); terminal state `PASS`, not `FAILED`. Production edits change the hash: rebuild affected manifest rows, re-freeze, rerun the Step 2.5 validator, and re-run the blind audit on the new pair.

### Step 5: Log

Update `memory/coverage.md`:
```
| File | Status | Metrics | Q Score | Coverage Gate | Blind Audit | Adversarial | Date |
```

- Statuses: `PASS`, `FAILED`, `BLOCKED_INCOMPLETE`, `BLOCKED_INFRA`, `SKIPPED_REVIEW`, `SKIPPED_BARREL`
- Metrics: `methods N/N, rows N/N, probes N/N` (COMPLEX files never log a bare test count as the metric)
- Coverage Gate: `pass`, `degraded`, `fail:<n>` (verbatim from the validator exit)
- Blind Audit: `clean:strict`, `clean:degraded`, `fix:<n>`, `rewrite`, `skipped`
- Adversarial: `clean`, `clean:fallback-local`, `<n> findings`, `<n> findings:fallback-local`, `skipped`, `blocked`, `not_run`
- Q Score persisted durably: `<score>/<applicable> (Q7=?,Q11=?,Q13=?,Q15=?,Q17=?)`

`SKIPPED_REVIEW` is degraded, never silently `PASS`. `BLOCKED_*` are non-success — never counted as completed or described as covered. Rows that never enter Step 4 persist `Adversarial=blocked`/`not_run`. A file is complete only when Status, Coverage Gate, Blind Audit, and Adversarial are all populated.

Per-file summary print: `[status] [file] — methods [N]/[N], rows [N]/[N], Q [N]/[applicable], gate: [pass|degraded|fail], blind: [...], adversarial: [...]`

**→ NEXT file in queue.**

---

## Completion (after queue empty)

1. **Backlog persistence:** unfixed out-of-scope issues → `memory/backlog.md`
2. **Knowledge curation** per `knowledge-curate.md`
2b. **Content-keyed review artifact (success only):** if the run modified any **production** file (incl. Step 4.5 fixes), write `memory/reviews/<base7>..<head7>-<slug>.md` with `range:`/`files:` headers per `review-artifact.md` — this run's blind audit + adversarial already reviewed that content, so pipeline gates accept it without a redundant `zuvo:review`. Skip when only test/docs files changed. **If the reviewed production edits are NOT yet committed** (no-commit session), HEAD cannot content-key them: write the PROVISIONAL form from `review-artifact.md` (working-tree blob hashes, `status: PROVISIONAL`) — it grants no coverage until the upgrade step after commit verifies the blobs and rewrites the range. Never write a normal-form artifact whose head does not contain the reviewed blobs.

### Final Test Quality Audit (REQUIRED — separate audit and fix steps, before the retro)

The per-file gates prove coverage; this closing gate proves QUALITY across
everything the run touched, graded by the real auditor. Read
`../../shared/includes/test-quality-gate.md` now and run its sequence — the
literal `Skill(zuvo:test-audit ...)` dispatch with an on-disk `zuvo/audits/`
report as proof; an inline Q-rescoring pass reported as this gate is a
substituted gate = INVALID.

**Step A1 — Audit** per the include, with:
- `TEST_SCOPE` = every test file this run created, extended, or rewrote, PLUS
  every pre-existing test file covering this run's production files (Step 1
  duplicates, sibling suites — the "already weak before we got here" tests).
- `FIX_COMMIT_PREFIX` = `test(write-tests):`

**Step A2 — Fix to Tier A** per the include (target: Tier A per file, ≥82% +
all critical gates; strengthening only, test files only, max 2 fix→re-audit
iterations, below-A after the cap = loud WARN + backlog, never silence). Two
write-tests-specific additions on top of the include:

- Tier D (AP13/AP16) on a PRE-EXISTING file is a rewrite, not a patch: route
  it through this skill's own Step 1 REWRITE path.
- Fixing tests can invalidate prior evidence: for every file A2 modified,
  re-run the Step 2.5 validator (line-form evidence may have shifted — prefer
  `path::test name` evidence, or run `test-coverage-gate.py refresh`, to make
  this a no-op), and re-run one blind-audit pass ONLY when the file's normhash
  changed per the Step 3.5 semantic freshness guard. The normhash decides, not
  intent.

Print the include's `[GATE: test-quality]` line and record
`test_quality=<PASS|WARN|N/A>:<worst tier>:<report path>` in the run telemetry.

### Retrospective (REQUIRED)

Follow `retrospective.md`: gate check → structured questions → TSV emit → markdown append. Write the retro BEFORE the terminal report.

3. **Report:**

```
COMPLETION GATE CHECK
[ ] Phase 0: reviewer preflight ran; failures announced at run start (not discovered at Step 3.5)
[ ] Step 1.6/1.7: inventory frozen to zuvo/contracts/ BEFORE writing; freeze validation exit 0 (or recorded degraded)
[ ] Step 2: test file(s) written with Write tool; split rule honored for large files
[ ] Step 2.5: executable validator ran; its output pasted; every public entry point FULL; Uncovered owned rows: 0
[ ] Step 3: Q-score with per-gate evidence (Q7,Q11,Q13,Q15,Q17); manifest Q values synced
[ ] Step 3.2: scoped coverage measured (or runner-lacks-support printed)
[ ] Step 3.3: mutation probes all killed; production restored (hash verified)
[ ] Step 3.5: blind audit ran (clean:strict|clean:degraded|skipped|blocked_infra)
[ ] Step 4: adversarial ran (clean|Nfindings|skipped|blocked|not_run)
[ ] Step 4.5: every confirmed in-scope production bug FIXED in-run; escalations loud
[ ] Step 5: coverage.md rows fully populated (Status+Gate+Blind+Adversarial)
[ ] Step A1/A2: [GATE: test-quality] emitted from a REAL zuvo:test-audit dispatch (on-disk zuvo/audits report) over touched + pre-existing in-scope test files; sub-A files fixed (or WARN + backlog); validator + blind audit re-run for A2-modified files
[ ] Step 2b: review artifact written IF production files changed
[ ] Final test run: all tests pass (N/N)
```

Any unchecked box → go back and complete that step first. After compaction/resume verify each against actual tool output in the current window, not memory.

```
WRITE-TESTS COMPLETE
-----
Files tested:  [N] ([M] new, [K] extended, [J] fixed)
Surface:       methods [N]/[N] FULL, owned rows [N]/[N], error paths [N]/[N]
Coverage gate: [N] pass, [M] degraded, [K] fail
Target cov:    st [%] / br [%] / fn [%] / ln [%] (scoped to production files)
Mutation:      [N]/[N] probes killed
Test audit:    [GATE: test-quality] [PASS|WARN|N/A] tier=[worst] files=[N] ([M] fixed up in-run) report=[zuvo/audits/...]
Below tier A:  [list with blocking findings, or "none"]
Q gates:       [N]/[applicable] avg (critical gates: all pass)
Blind audit:   [N] clean, [M] failed/rewrite, [K] skipped
Validation:    [full-suite|scoped:touched-tests]
Failures:      pre-existing: [N], new in scope: 0
FAILED files:  [list or "none"]
BLOCKED_INCOMPLETE: [list or "none"]
BLOCKED_INFRA: [list or "none"]
SKIPPED_REVIEW: [list or "none"]
SKIPPED_BARREL: [list or "none"]
Run: <ISO-8601-Z>	write-tests	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log`:

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. Exit 2 `RETRO_REQUIRED` → execute the retro bash first; never `ZUVO_SKIP_RETRO_GATE=1`. After success print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`).

Run one final full-suite validation, or explicitly scope the failure count to touched test files before printing `new in scope: 0`.

**Do NOT print WRITE-TESTS COMPLETE if any file is missing Status/Coverage Gate/Blind Audit/Adversarial, has uncovered owned rows, a failing or unrun validator, Q7=0 or Q11=0, a surviving mutation probe, an undispatched final test audit (Step A1), or status `BLOCKED_INCOMPLETE`/`BLOCKED_INFRA`.** A file legitimately below Tier A after 2 fix cycles does not block the report — it blocks only its own silent inclusion in the tier-A count. (A run that is DRAFT/BLOCKED_INFRA from preflight reports its terminal block instead — with Q7=1 and Q11=1 still required of every written file, so the tests are sound even though review could not run.)

---

## Resume / Crash Recovery

On start, read `memory/coverage.md` AND glob `$ZUVO_DIR/contracts/*.coverage.json`. Old pre-blind-audit rows: normalize once (add empty Blind Audit/Adversarial cells, note `legacy-pre-blind-audit`), resume at Step 3.5. Rows without a Coverage Gate cell are pre-validator legacy: re-run Step 2.5 against the current files before trusting their status.

| Status | Blind Audit | Adversarial | Resume action |
|--------|-------------|-------------|---------------|
| PASS | `clean:strict` | present | Skip |
| FAILED | any | any | Skip (already backlogged) |
| BLOCKED_INCOMPLETE | any | `blocked`/`not_run` | Resume at Step 2.5, close every uncovered row |
| BLOCKED_INFRA | `skipped` | `blocked` | Re-run preflight; resume at Step 3.5 when infrastructure is back |
| SKIPPED_REVIEW | `clean:strict` | `skipped` | Re-process Step 4 only |
| SKIPPED_BARREL | `skipped` | `not_run` | Skip |
| (row absent, manifest `status=inventory`) | - | - | Resume at Step 2 (inventory already frozen — validate freshness first) |
| (row absent, manifest `status=final`, validator passes) | - | - | Resume at Step 3 |
| (absent entirely) | - | - | Process from Step 1 |

A test file on disk absent from coverage.md = partial run: if it carries the `Generated by zuvo:write-tests` marker, delete and re-process from Step 1; otherwise assess in Step 1 (ADD TO / REWRITE). A manifest whose hash no longer matches production is stale — rebuild it, never trust its rows. Auto mode re-runs discovery to rebuild the queue.

---

## Principles

1. Read production code before planning tests. Every assertion traces to real behavior.
2. Inventory before writing. The public surface is frozen before the first test exists — writing first invites rationalizing the gaps away.
3. Coverage completeness is proved by a program, not claimed by the writer. The validator's output is the gate; test count is never a progress signal for COMPLEX files.
4. Test what the code OWNS, mock what it DELEGATES.
5. ONE file, FULL pipeline. No batching of files or pipeline steps.
6. Blind coverage audit and adversarial review are separate gates. Step 4 never runs until Step 3.5 is clean, and reviewer availability is proven in Phase 0 — not discovered at Step 3.5.
