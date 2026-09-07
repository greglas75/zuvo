## Phase 1: Type Detection + CQ Pre-Audit + Approval Gate

### Test File Auto-Detection

If the target is a test file (`.test.*`, `.spec.*`, `__tests__/*`), auto-set type to IMPROVE_TESTS. Skip keyword detection and use Q1-Q25 as the primary audit framework.

### Keyword-Based Detection (production files)

| Keywords in user description | Type |
|-----------------------------|------|
| extract, split, helper | EXTRACT_METHODS |
| split file, god class | SPLIT_FILE |
| circular, cycle | BREAK_CIRCULAR |
| move, relocate | MOVE |
| rename | RENAME_MOVE |
| interface, DIP, decouple | INTRODUCE_INTERFACE |
| error handling, empty catch | FIX_ERROR_HANDLING |
| dead code, unused | DELETE_DEAD |
| simplify, reduce complexity | SIMPLIFY |

Default when no keywords match: EXTRACT_METHODS.

### Complexity-shape gate (SPLIT_FILE / GOD_CLASS / SIMPLIFY only)

These three intents PROMISE complexity reduction, and 13% of measured split runs broke that promise
invisibly — the file halved while the worst function stayed intact or grew (101 runs, 4 repos,
2026-08-20; the pathology cases: maxfn 103→103 after −614 lines, 63→**87**, 43→45 twice). Two
obligations before any edit, both enforced by the pre-push gate on contract `version >= 5`:

1. **Record the baseline NOW.** Measure the target with the canonical snippet (or CodeSift
   `analyze_complexity` — same tool for before and after) and write
   `prove.complexity_before = "maxfn:<loc>,branches:<n>,loc:<n>"` into the CONTRACT. See
   "Effectiveness fields (v5)" in `refactor-reference.md`. A baseline recorded after the work is
   not a baseline.
2. **Classify the complexity shape — ADDITIVE vs ESSENTIAL** — per the signals table in
   `refactor-reference.md`. ADDITIVE (independent responsibility groups): proceed with the split.
   ESSENTIAL (one function holds >40% of the file's branches; ordered first-match cascade; a
   normalizer whose size is fields × defaults; a state machine threading mutable state): a file
   split will RELOCATE the complexity, not reduce it. Route the plan at the worst FUNCTION —
   table-drive the cascade, extract pure predicates the core calls, flatten nesting — and only if
   none applies, plan to record `complexity_reduced = "essential:...:reason=<shape>"` and say in
   the completion block that the file remains complex. Print the classification:
   `[COMPLEXITY-SHAPE] {ADDITIVE|ESSENTIAL}: <one-line evidence, e.g. "maxfn holds 298/512 branches">`

### GOD_CLASS Auto-Escalation

After keyword detection, ALWAYS check the target file for GOD_CLASS thresholds:

- File exceeds 600 lines AND has 5+ distinct responsibilities (groups of related public methods with separate concerns)

If thresholds are met, override the detected type to GOD_CLASS and display:

```
GOD_CLASS DETECTED: [filename] ([N]L, [M] responsibilities)
Escalating to extended splitting protocol.
```

The GOD_CLASS protocol uses iterative decomposition: extract one responsibility at a time, verify tests pass after each extraction, then repeat. Do not attempt to split all responsibilities in one pass.

### CQ Pre-Audit

Before displaying the plan, run CQ1-CQ40 on the target file. Print ALL 40 gates:

```
CQ PRE-AUDIT: [filename] ([N]L)
CQ1=1 CQ2=0 CQ3=N/A CQ4=0 CQ5=0 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=0
CQ11=1 CQ12=0 CQ13=1 CQ14=0 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=0
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=0 CQ25=1 CQ26=N/A CQ27=1 CQ28=0
Score: 13/24 applicable -> FAIL
Critical gates: CQ4=0(no orgId:42) CQ5=0(PII:54,82)
Fix targets: CQ5, CQ14, CQ19, CQ10, CQ12
```

Showing only failures hides false positives in the 1s. All 28 scores must be visible.

### CONTRACT State File

The CONTRACT JSON schema (v6) and the migration rules live in
`../../../shared/includes/refactor-reference.md` -> "CONTRACT State File". Create
`zuvo/contracts/refactor-{target-hash}.json` per that schema (`{target-hash}` = first 8 chars of
SHA-256 of the relative target path). It now includes the `prove` block the commit-gate reads.
Update it after each phase; `continue` resumes from the last recorded `stage`.

### Sub-Agent Dispatch (FULL mode)

Refer to `env-compat.md` for the correct dispatch pattern per environment.

The orchestrator passes the following to each agent: **target file**, **CODESIFT_AVAILABLE** flag, and **repo identifier** (`$TARGET_REPO`, resolved in Phase 0 from `git rev-parse --show-toplevel` — never from `list_repos()`). Agents must NOT call `list_repos()` themselves — the orchestrator owns the identifier.

Dispatch two agents in parallel (background) to inform the plan:

```
Agent 1: Dependency Mapper
  model: "sonnet"
  type: "general-purpose"  # read-only: Read + CodeSift only, no Edit/Write (Explore lacks mcp__codesift__*)
  instructions: trace all importers and callers of the target file (see details below)
  input: target file, CODESIFT_AVAILABLE, repo identifier

Agent 2: Existing Code Scanner
  model: "sonnet"
  type: "general-purpose"  # read-only: Read + CodeSift only, no Edit/Write (Explore lacks mcp__codesift__*)
  instructions: search codebase for helpers/utilities similar to planned extractions (see details below)
  input: target file, CODESIFT_AVAILABLE, repo identifier, planned extraction list
```

#### Agent 1: Dependency Mapper (default tier, read-only)

Trace all importers and callers of the target file. Build a dependency map: direct importers, transitive dependents (one level up), exported symbols and where each is consumed, risk assessment for export changes.

**The opposite decision — WIRING dead code in rather than deleting it — is `surface activation`, and
it is not a refactor.** The moment previously unreachable production code becomes reachable, every
path in it is new attack surface that has never run: it was never load-bearing, so nothing about it
was ever reviewed under load. Classify it explicitly and, **before wiring**, trace every activated
network/DB call and verify each of: mounted path, authentication source, tenant/contest/user scoping,
idempotency, timeout, and response validation. Add every file those answers touch to the scope fence
**before** editing — activation almost always pulls in a route table, an auth middleware, and a
client caller that the original fence did not list. Front-loading this is the whole point: skipping
it is what turns one activation into four adversarial passes chasing the same class of finding.

For DELETE_DEAD targets, consumer proof additionally requires a repo-wide search for concrete route-path/string literals (a string caller in clients, tests, or proxies is a live contract consumer even when the unit has zero imports) and a scan of docs/specs/runbooks for the symbol. A docs-only reference is not runtime use, but it must be dispositioned before scope freeze — update the doc in-fence or backlog it — never ignored.

**CodeSift:** `find_references(repo, symbol_name)` for each export, `trace_call_chain(repo, symbol_name, direction="callers", depth=2)` for critical functions. **Fallback:** grep for imports.

#### Agent 2: Existing Code Scanner (lightweight tier, read-only)

Search the codebase for existing helpers, utilities, or patterns similar to planned extractions. Prevents creating duplicates.

**CodeSift:** `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` and `search_symbols(repo, query, detail_level="compact")`. **Fallback:** grep for function names and patterns.

### Phase 1 Planning

Produce the refactoring plan incorporating sub-agent results (when available):

1. **Scope freeze** -- List every file that may be modified. No file outside this list may be touched during execution.

   **Order the extraction list by risk, lowest first — and treat that as sequencing, not permission
   to stop.** When a task bundles units of very different risk (a hook owning one async action is
   low-risk; a controller owning cross-wired modal state, or a parser-strategy restructure of an
   untested unit with external I/O and callbacks, is a RESTRUCTURE), do the self-contained,
   characterizable units FIRST and commit each — so the run banks verified work before it reaches
   the part that can go wrong. Then attempt the risky unit.

   Scoping *down* is the user's call, not the run's. If the risky unit genuinely cannot be completed
   — no fixtures can be built, or the work exceeds the remaining window — the run ends **PARTIAL,
   loudly**: name the unit, state why in one paragraph, give the concrete follow-up, record it in
   the commit body and the backlog, and print the partial verdict in the completion block. What is
   forbidden is the quiet version — reporting COMPLETE for a subset, or discovering the deferral
   only in the backlog. "A verified partial beats an unverifiable full restructure" is true; "a
   partial reported as done" is the failure it turns into when it is not said out loud.
2. **Extraction list** -- For each function or block to extract: source location, destination, new signature.
3. **Dependency impact** -- From the Dependency Mapper: which files need import updates, which tests need adjustment.
4. **Existing code reuse** -- From the Existing Code Scanner: existing utilities that can replace planned extractions.
5. **Test discovery** -- Before routing, find and evaluate existing tests. **Skip this step entirely if the target is a type file or config file** (route directly to VERIFY_COMPILATION at step 6, priority 1).

   ```
   TEST DISCOVERY: [target file]
   -----------------------------------------------
   Test file:  [path or NONE]
   Found via:  [co-located .test.* / .spec.* / __tests__/* / grep import]
   Q-triage:   Q7=[0|1] Q11=[0|1] Q13=[0|1]
   Coverage:   units_total=[N] units_covered=[M] gap=[N-M]
   -----------------------------------------------
   ```

   Steps:
   a. Search for test file: co-located `.test.*` / `.spec.*`, `__tests__/` directory, grep for imports of target
   b. If test file found: read it, run quick Q-audit on 3 critical gates only (Q7=error-path coverage, Q11=branch coverage, Q13=imports actual production function). This is a partial triage, not a full Q1-Q25 audit.
   c. **Coverage of the refactoring surface (CRITICAL — separate from Q-triage).** Q-triage measures how *good* the found test is; coverage measures whether it actually *exercises the code being moved*. A test can score Q7=Q11=Q13=1 and still touch only one of many units. Compute:
      - `units_total` = the count of independent units this refactor will move/extract/relocate. For SPLIT_FILE / GOD_CLASS / EXTRACT_CLASS: every top-level component/function/class that lands in a new module. For EXTRACT_METHODS: the public methods whose internals change. Get this from the planned extractions, not a guess.
      - `units_covered` = how many of those units the existing test **actually executes at runtime** (rendered/called with real input and asserted on — not merely imported, and not landing in an empty-state/early-return branch). When unsure whether a unit is truly exercised, count it as NOT covered.
      - `coverage_gap = units_total - units_covered`, and list the uncovered unit names.
   d. Record `test_audit_before` in contract state: `{ "test_file": "...", "q7": 0|1, "q11": 0|1, "q13": 0|1, "units_total": N, "units_covered": M, "uncovered_units": [...] }`
   e. If no test file found: record `{ "test_file": null, "units_total": N, "units_covered": 0, "uncovered_units": [...] }`

Record the accepted input domain and negative behavior (throw, rejection, filtering or fallback)
for Q7; follow the canonical Q7 definition. Tests of a private helper are evidence for that
helper's scope, not for every branch of its caller. Freeze the characterization package before
baseline and reserve a separate test path for any new exported helper's direct tests.

6. **Test mode routing** -- Route based on test discovery results. Evaluate top-to-bottom, first match wins:

| Priority | Condition | Test mode |
|----------|-----------|-----------|
| 1 | Target is a type file (`.d.ts`, `.types.ts`) or config (`.config.*`, `.*rc`) | VERIFY_COMPILATION |
| 2 | No test file found (test_file = null) | WRITE_NEW |
| 2.5 | **Pure structural move** — every precondition below holds | **VERIFY_MOVE** |
| 3 | **`coverage_gap > 0`** (one or more units being moved are NOT exercised by any test) | **CHARACTERIZE_GAP** |
| 4 | Test found AND Q7=1 AND Q11=1 AND Q13=1 AND `coverage_gap = 0` | RUN_EXISTING |
| 5 | Test found AND (Q7=0 OR Q11=0 OR Q13=0) AND `coverage_gap = 0` | IMPROVE_TESTS |

Note: priority 1 (VERIFY_COMPILATION) is checked **before** test discovery runs. If the target is a type/config file, skip test discovery entirely.

**DELETE_DEAD exception (overrides priorities 2-5 for the deleted units):** when the refactor DELETES a unit and zero production consumers are proven (symbol references + repo-wide import/re-export/dynamic/string-literal search per the Dependency Mapper), do NOT write or improve tests for the code being removed — the green pre-edit package baseline is the characterization lock. Record it before editing — `~/.zuvo/refactor-contract baseline --mode dead "<the green pre-edit
package command>"`, then append the unit count and evidence with
`~/.zuvo/refactor-contract set prove.characterization "<value>:<N>u:<evidence>"` if the deletion
needs more than the measured result. Tests whose sole subject is the deleted unit are deleted with it; tests-only consumers do not make dead code live.

**Why priority 3 outranks RUN_EXISTING (the failure this prevents):** a single test that passes Q7/Q11/Q13 can still exercise only one of N units being relocated. `RUN_EXISTING` would then go green while proving nothing about the other N−1 units — the refactor "verifies" against a test that never touches most of the moved code. Whenever `coverage_gap > 0`, you MUST write characterization tests for the uncovered units **before** touching production code. Build success, type-check, and static import resolution are NOT substitutes — they prove the code links, not that behavior is preserved. This gate is non-negotiable for SPLIT_FILE / GOD_CLASS / EXTRACT_CLASS, where moving unexercised units is the whole job.

**Priority 2.5 — VERIFY_MOVE (pure structural move).** Authoring DB-mocked characterization tests
for a split that changes zero bytes of logic is disproportionate, and the barrel + verbatim diff is
the *stronger* proof anyway. But it is only stronger when the move is genuinely inert, so all five
preconditions must hold and each must be **shown**, not asserted:

1. Every moved unit is **byte-identical** to its pre-refactor lines — proven per symbol with
   `../../../shared/includes/regression-fence.md` (blob/normalized-diff), not by reading the diff.
2. The **original path survives as a re-export barrel**, so every existing import specifier still
   resolves to the same symbol. A moved import path is a public-API change → not this tier.
3. **No top-level side effects** in the moved lines (no module-init work, no registration call, no
   mutable module-scope state). Splitting a module changes *when* top-level code runs; byte
   identity does not protect against that. Grep the moved ranges for statements outside a
   declaration and record the result.
4. **No new import cycle** introduced by the split (`find_circular_deps` before and after, or the
   language's own cycle check). A barrel is the classic way to create one.
5. Existing **consumer suites run green** before and after, and they actually import through the
   barrel path (if nothing imports it, there is no proof — fall through to priority 3).

Record `prove.characterization = "verify-move:<pre-refactor sha7>:<N>u:<consumer suite path>"`.
If ANY precondition fails or cannot be checked with the tools present, this tier does not apply —
fall through to CHARACTERIZE_GAP. "I could not run the cycle check" is a fall-through, not a pass.

**Transitive coverage (how `units_covered` is counted).** A moved unit counts as covered when a test
exercises it *directly* — or transitively, under one narrow condition: the unit is **not exported**,
its **only** caller is a single exported symbol, and an existing test drives that symbol through the
moved lines. The last part is the catch: it must be **measured** (line/branch coverage over the
pre-refactor file showing the moved ranges are hit), never inferred from "the test calls the parent."
Without coverage tooling the condition is unverifiable, so the unit is uncovered → CHARACTERIZE_GAP.
This exists so pure loop-body and private-helper extractions are not forced into disproportionate
mock scaffolding; it is not a general "the entry-point test covers everything" licence — an
independently reachable (exported) unit is never transitively covered.

7. **CQ gate targets** -- Which CQ failures from the pre-audit should be fixed during this refactoring.

### Questions Gate

If there is genuine uncertainty after planning, present questions to the user (max 4). Update the CONTRACT with answers, then proceed to the approval gate.

In BATCH mode: skip questions, proceed with the safest default.

### Plan Display (full mode only; skipped in batch) — NO approval pause

**Persist the plan first:** before displaying, WRITE the approved extraction list (order,
targets, leaves-first sequencing, per-step verify command) into the CONTRACT state file as its
plan block. The executor's payload is the contract — a plan that lives only in this transcript
cannot be executed in isolation.

Display the plan:

```
REFACTOR PLAN: [filename] ([N]L)
Type: [EXTRACT_METHODS / SPLIT_FILE / ...]
Scope: [N] files
Extractions: [summary of planned changes]
CQ targets: [which CQ failures to fix]
Test mode: [RUN_EXISTING / VERIFY_MOVE / CHARACTERIZE_GAP / WRITE_NEW / IMPROVE_TESTS / VERIFY_COMPILATION]
Coverage: units_total=[N] units_covered=[M] gap=[N-M]
```

Then **proceed immediately to Phase 2, printing `[AUTO-APPROVED]`** — do NOT ask
"Zatwierdzasz?" / "Approve this scope?" / present an options menu and wait. The user's
invocation of `zuvo:refactor <target>` IS the approval; pausing after every plan is the
exact friction the no-approval-gates policy removed (skills execute; only `plan-only`
and `--dry-run` gate output). The user can always interrupt.

Legitimate stops are ONLY: (a) `plan-only` mode — stop here by design; (b) the genuine-
uncertainty questions from the section above (contradictory instructions, destructive
ambiguity — max 4, and only when planning genuinely cannot resolve them). "Which of two
reasonable scopes?" is NOT genuine uncertainty — pick the one that best matches the
user's words, state the choice in one line, and proceed.

If the user replies mid-run with a plan change (they interrupted or answered a genuine-
uncertainty question):

**Cosmetic change** (wording, extraction names, minor scope adjustments within same files):
1. The orchestrator recomputes scope, extractions, and test mode inline.
2. Sub-agents are NOT re-dispatched — their analysis remains valid.
3. Print the updated plan and continue (no new pause).

**Material change** (different type, new files added to scope, fundamentally different extraction strategy):
1. Re-dispatch Dependency Mapper and Existing Code Scanner with updated inputs.
2. Recompute plan incorporating new agent results.
3. Print the updated plan and continue (no new pause).

---
