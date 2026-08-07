---
name: refactor
description: >
  Structured refactoring runner with ETAP workflow, resumable CONTRACT, and
  batch processing. Use when restructuring code, extracting methods, splitting
  files, breaking circular dependencies, or cleaning up god classes. NOT for
  new features (use zuvo:build). Execution modes: full (default), batch <file>
  (queue processing). Control flags: plan-only, no-commit, continue.
category: Core
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols
    - get_symbol
    - get_symbols
    - get_file_outline
    - find_references          # KEY — impact analysis before changing signatures
    - trace_call_chain         # downstream effect of refactor
    - rename_symbol            # KEY — cross-file rename without manual Edit
    - find_dead_code           # remove what becomes unused after refactor
    - find_unused_imports      # post-refactor cleanup
    - find_clones              # extract-method opportunities
    - find_circular_deps       # break cycles is a common refactor goal
    - search_text
  by_stack:
    typescript: [get_type_info, resolve_constant_value]
    javascript: []
    python: [python_audit, analyze_async_correctness, resolve_constant_value]
    php: [php_project_audit, php_security_scan, resolve_php_namespace]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_middleware, astro_svg_components]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders, analyze_context_graph, trace_component_tree]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service, trace_php_event, find_php_views]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:refactor

A senior architect executing a structured refactoring workflow. Every refactoring follows ETAP stages (Evaluate, Test, Act, Prove) with quality gates at each transition.

## Definition of Done (non-negotiable — read before you start)

A refactor is **BLOCKED until proven**, and the proof is the **CONTRACT**, not your say-so. The
canonical order is **Prove → record in CONTRACT → Gate → Commit (LAST)**. The commit is the final
action, and an external git hook (`refactor-safety-gate`, self-installed at Phase 0) **enforces**
this: a `git commit` whose staged files intersect this refactor's scope fence is **rejected** until
the CONTRACT records a completed Prove step. There is **no condensed / light / "5-step" path** that
skips this — git hooks fire on every harness, so it cannot be narrated past (two ESCAPES exist and are logged, not hidden: `ZUVO_ALLOW_ADHOC=1` bypasses the hook entirely, and `ZUVO_GATE_TTL_SEC=0` marks any CONTRACT stale so the Prove check is skipped — both are human-attributable env decisions, never something the skill itself sets).

The four **SAFETY** gates — never skippable, never reducible by "user scope", never "looks small so I skipped it":
1. **Characterization coverage** of every moved unit, green on the PRE-refactor code (before touching it).
2. **Independent CQ Auditor** (blind audit) → record `prove.blind_audit ∉ {skipped,not_run}`.
3. **Adversarial review** on the final diff → record `prove.adversarial ∉ {skipped,not_run}`.
4. **Remediation**: in-fence bugs the audit/adversarial surface are FIXED in this run (staged before
   the gated commit), NOT backlogged. Only out-of-fence / user-declined items defer (each documented).

**TELEMETRY** (CONTRACT, retro, run-log) is cheap — always do it. **BUILD SCOPE** (targeted vs full
`turbo build`) the user MAY narrow, but only by DECLARING it. Skipping a SAFETY gate, or running it
and parking its findings, = the run is `BLOCKED(unsafe)`. Full stop. Everything below is HOW; this is WHAT.

## Mandatory File Loading

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
  2. ../../shared/includes/no-pause-protocol.md   -- [READ | MISSING -> WARN] (HARD: no mid-batch pauses)
  3. ../../shared/includes/regression-fence.md    -- [READ | MISSING -> WARN] (proves MOVED_VERBATIM instead of asserting it)
```

These files are loaded before reading the refactor target.

### PHASE 0 — Commit-gate self-install (run this bash; ungated, fail-open)

Export the AI-run marker and ensure the external refactor commit-gate is active for this repo. The
gate is the bind that makes the Definition of Done real — an agent cannot skip a git hook. It no-ops
when the repo has no active refactor CONTRACT, fail-opens if anything is missing (never blocks setup).

```bash
# (No ZUVO_AI_RUN export — it would not survive into the agent's later, separate commit shell.
#  The gate detects an AI run from the ambient harness env: CLAUDECODE / CODEX_SANDBOX /
#  CURSOR_TRACE_ID / ANTIGRAVITY_SESSION_ID — always set at session level, so the gate fires
#  on real commits without any export. Verified end-to-end in a temp repo.)
# Probe EVERY host's install root, not just the Claude marketplace cache: on Codex/Cursor the
# plugin lives under ~/.codex or ~/.cursor, so a Claude-only probe printed "not found" on every
# run there — false installer-missing telemetry that hid a genuinely absent gate.
_GATE=$(ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/hooks/refactor-safety-gate.sh \
           ~/.codex/scripts/refactor-safety-gate.sh ~/.cursor/scripts/refactor-safety-gate.sh \
           ~/.gemini/antigravity/hooks/refactor-safety-gate.sh \
           ~/.codex/.tmp/plugins/plugins/zuvo/hooks/refactor-safety-gate.sh 2>/dev/null | head -1)
_INST=$(ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/install-refactor-gate.sh \
           ~/.codex/scripts/install-refactor-gate.sh ~/.cursor/scripts/install-refactor-gate.sh \
           ~/.gemini/antigravity/scripts/install-refactor-gate.sh 2>/dev/null | head -1)
# Is the gate even able to fire? It detects an AI run from the ambient harness env; if none of
# these is set the gate no-ops on the human's commits by design — say so instead of implying
# the repo is protected.
_HARNESS=""
for v in CLAUDECODE CODEX_SANDBOX CURSOR_TRACE_ID ANTIGRAVITY_SESSION_ID; do
  eval "[ -n \"\${$v:-}\" ]" && _HARNESS="$_HARNESS $v"
done
if [ -n "$_GATE" ] && [ -n "$_INST" ]; then
  sh "$_INST" "$_GATE" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "[refactor-gate] gate=$_GATE"
  echo "[refactor-gate] ai-harness-detected:${_HARNESS:- NONE (gate will no-op — commits look human)}"
else
  echo "[refactor-gate] NOT INSTALLED — gate='${_GATE:-missing}' installer='${_INST:-missing}';"
  echo "[refactor-gate] searched ~/.claude/plugins/cache, ~/.codex, ~/.cursor. Re-run scripts/install.sh."
  echo "[refactor-gate] in-skill self-check still applies, but the commit bind is ABSENT this run."
fi
```

### PHASE 0.5 — Classify (read target, determine refactor type)

After CodeSift setup, read the target file(s). Determine refactor type:
- **RENAME:** symbol rename, file move
- **EXTRACT:** extract function/class/module
- **SPLIT:** split large file into smaller modules
- **INLINE:** consolidate/inline scattered logic
- **RESTRUCTURE:** architectural change (module boundaries, dependency direction)

Print: `[CLASSIFIED] Refactor type: {RENAME|EXTRACT|SPLIT|INLINE|RESTRUCTURE}`

**First check the working tree — a prior interrupted attempt changes what "before" means.** If the
target already has staged or unstaged modifications (`git status --porcelain -- <target>`), this is
almost certainly a resumed/retried run, and reading the file as-is silently measures a
half-refactored state as the baseline: the CQ pre-audit scores partially-extracted code, the
"before" snapshot is wrong, and the run may re-extract what is already extracted.

```bash
git status --porcelain -- <target>          # empty → clean start, proceed normally
git diff HEAD -- <target> | head -60        # tracked changes ('??' in status = untracked, no diff)
```

**A dirty target is NOT automatically a resumable attempt** — it may be the user's unrelated
work-in-progress, and absorbing that into the baseline would quietly make their edits part of "the
code before my refactor" (and part of your commit). Decide by evidence, not assumption:

- A CONTRACT exists for this target with `stage != COMPLETE` → this IS a resumed run. Treat the
  current state as "before" for the CQ pre-audit, and reconcile with the CONTRACT and any CHANGELOG
  entry the earlier attempt wrote, so the run continues rather than duplicates or reverts it.
- No CONTRACT, or the changes do not look like the recorded plan → treat it as **foreign WIP**.
  Do not absorb it and do not stash it silently: say what is uncommitted and ask (or, when
  non-interactive, stop with `BLOCKED_DIRTY_TARGET`). Refactoring on top of someone's unfinished
  edit produces a diff neither of you can review.

Record which baseline was used either way — a "before" score measured against the wrong tree makes
the whole before/after comparison meaningless.

### PHASE 1 — Conditional Load (based on refactor type)

| Include | RENAME | EXTRACT/SPLIT | INLINE | RESTRUCTURE |
|---------|--------|---------------|--------|-------------|
| `../../shared/includes/env-compat.md` | Full | Full | Full | Full |
| `../../shared/includes/quality-gates.md` | **SKIP** | CQ section only | CQ section only | Full |
| `../../rules/cq-patterns.md` | **SKIP** | **SKIP** | Full | Full |
| `../../rules/cq-checklist.md` | **SKIP** | **SKIP** | **SKIP** | Full |
| `../../rules/file-limits.md` | **SKIP** | Full | **SKIP** | Full |
| `../../rules/testing.md` | If tests affected | If tests affected | If tests affected | Full |
| `../../shared/includes/test-edge-cases.md` | **SKIP** | If tests affected | **SKIP** | If tests affected |
| `../../rules/security.md` | **SKIP** | **SKIP** | **SKIP** | If security-sensitive |

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file]
```

### DEFERRED — Load at completion

```
  ../../shared/includes/run-logger.md        -- [READ at final step]
  ../../shared/includes/retrospective.md     -- [READ at final step]
  ../../shared/includes/documentation-mandate.md -- [READ at final step]
  ../../shared/includes/knowledge-prime.md   -- [READ at start if available | MISSING -> degraded]
  ../../shared/includes/knowledge-curate.md  -- [READ at final step if available | MISSING -> degraded]
```

If any PHASE 0 file missing, STOP. The plugin installation is incomplete.

---

## Argument Parsing

### Execution Modes (mutually exclusive)

```
$ARGUMENTS = empty         -> FULL mode (default)
$ARGUMENTS = "full"        -> FULL mode (explicit)
$ARGUMENTS = "batch <file>"-> BATCH mode (process queue file, zero stops)
$ARGUMENTS = other         -> task description, FULL mode
```

### Control Flags

```
"no-commit"                -> Skip auto-commits (show diff + proposed message instead)
"plan-only"                -> Stop after the approval gate (Phase 1). Do not enter Phase 2 or Phase 3.
"continue"                 -> RESUME: scan zuvo/contracts/refactor-*.json, resume active contract
"continue <path>"          -> RESUME: user passes readable file path (e.g., src/services/order.service.ts), skill computes hash internally to find zuvo/contracts/refactor-{hash}.json
```

**Flag priority rules:**
- `continue` has highest priority: it overrides flags (except `no-commit`). Mode is always `full` — if the contract was created with a legacy mode (`quick`/`standard`/`auto`), silently upgrade to `full` and log the migration.
- `no-commit` and `plan-only` combine freely: `zuvo:refactor no-commit` runs full mode without committing. Contract stage is set to `EXECUTION_COMPLETE` (not `COMPLETE`) so `continue` can resume from the uncommitted state.
- `plan-only` and `continue` are mutually exclusive (continue resumes past the plan phase).

---

## Phase 0: Stack Detection and CodeSift Setup

### Knowledge Prime

Run `knowledge-prime.md`: `WORK_TYPE = "implementation"`, `WORK_KEYWORDS = <target file/module names>`, `WORK_FILES = <files to refactor>`.

### Tech Stack

Detect the project's tech stack from config files:

| Signal | Stack | Rules to load |
|--------|-------|--------------|
| `tsconfig.json` | TypeScript | `../../rules/typescript.md` |
| `package.json` with `next` | Next.js | `../../rules/react-nextjs.md` |
| `package.json` with `@nestjs/core` | NestJS | `../../rules/nestjs.md` |
| `pyproject.toml` or `.py` files | Python | `../../rules/python.md` |
| `composer.json` | PHP | `../../rules/php.md` |
| `composer.json` with `yiisoft/yii2` | Yii2 | `../../rules/yii2.md` (with php.md) |
| `astro.config.*` | Astro | `../../rules/astro.md` |
| `go.mod` | Go | `../../rules/go.md` |
| `Cargo.toml` | Rust | `../../rules/rust.md` |
| `*.csproj` / `*.sln` | .NET | `../../rules/dotnet.md` |
| `Gemfile` | Ruby | `../../rules/ruby.md` |
| `vitest.config.*` | Vitest test runner | |
| `jest.config.*` | Jest test runner | |

Print: `STACK: [language] | RUNNER: [test runner]`

### CodeSift Setup

Follow `codesift-setup.md`: check availability, `list_repos()` once (cache identifier), `index_folder(path=<root>)` if not indexed.

### Pre-Scan

Run 6 analysis calls to understand WHAT to refactor before planning HOW:

1. `analyze_complexity(repo, top_n=10, file_pattern=SCOPE)` -- Is the target among the most complex files? Which functions are worst?
2. `analyze_hotspots(repo, since_days=90)` -- Is the target a churn hotspot? Changed often + complex = high-value refactor.
3. `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` -- Copy-paste blocks with other files? DRY extraction candidates.
4. `find_dead_code(repo, file_pattern=SCOPE)` -- Unused exports in scope. Delete BEFORE refactoring (less code to move).
5. `classify_roles(repo, file_pattern=SCOPE)` -- Symbol role classification: dead/leaf/core/entry
6. `find_circular_deps(repo, file_pattern=SCOPE)` -- Cycle detection for BREAK_CIRCULAR type

Print:

```
REFACTOR PRE-SCAN
------------------------------------
Complexity: target ranks #N/10 (cyclomatic X, function: Y)
Hotspot:    changed N times in 90 days (rank in repo)
Clones:     N blocks (X% similar) with [file:lines]
Dead code:  N unused exports ([names])
Roles:      N dead symbols (delete first), N leaf (safe to move), N core (careful)
Cycles:     [N cycles detected | no cycles]
------------------------------------
```

Feed pre-scan data into the extraction plan:
- Clone blocks -> extract to shared module. Dead exports -> delete before refactoring.
- Highest-complexity functions -> prioritize splitting these first. Hotspot confirmation -> validates high-value.
- `classify_roles`: dead = delete before refactoring, leaf = safe extraction, core = careful handling, entry = do not move without re-export.

When CodeSift unavailable: skip pre-scan. Log `[DEGRADED: classify_roles/find_circular_deps unavailable]`.

---

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

The CONTRACT JSON schema (v3) and the v2->v3 migration rules live in
`../../shared/includes/refactor-reference.md` -> "CONTRACT State File". Create
`zuvo/contracts/refactor-{target-hash}.json` per that schema (`{target-hash}` = first 8 chars of
SHA-1 of the relative target path). It now includes the `prove` block the commit-gate reads.
Update it after each phase; `continue` resumes from the last recorded `stage`.

### Sub-Agent Dispatch (FULL mode)

Refer to `env-compat.md` for the correct dispatch pattern per environment.

The orchestrator passes the following to each agent: **target file**, **CODESIFT_AVAILABLE** flag, and **repo identifier** (from the orchestrator's own `list_repos()` call in Phase 0). Agents must NOT call `list_repos()` themselves — the orchestrator owns that call.

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

**DELETE_DEAD exception (overrides priorities 2-5 for the deleted units):** when the refactor DELETES a unit and zero production consumers are proven (symbol references + repo-wide import/re-export/dynamic/string-literal search per the Dependency Mapper), do NOT write or improve tests for the code being removed — the green pre-edit package baseline is the characterization lock. Record `prove.characterization = "dead:<pre-refactor sha7>:<N>u:<evidence>"` before editing. Tests whose sole subject is the deleted unit are deleted with it; tests-only consumers do not make dead code live.

**Why priority 3 outranks RUN_EXISTING (the failure this prevents):** a single test that passes Q7/Q11/Q13 can still exercise only one of N units being relocated. `RUN_EXISTING` would then go green while proving nothing about the other N−1 units — the refactor "verifies" against a test that never touches most of the moved code. Whenever `coverage_gap > 0`, you MUST write characterization tests for the uncovered units **before** touching production code. Build success, type-check, and static import resolution are NOT substitutes — they prove the code links, not that behavior is preserved. This gate is non-negotiable for SPLIT_FILE / GOD_CLASS / EXTRACT_CLASS, where moving unexercised units is the whole job.

**Priority 2.5 — VERIFY_MOVE (pure structural move).** Authoring DB-mocked characterization tests
for a split that changes zero bytes of logic is disproportionate, and the barrel + verbatim diff is
the *stronger* proof anyway. But it is only stronger when the move is genuinely inert, so all five
preconditions must hold and each must be **shown**, not asserted:

1. Every moved unit is **byte-identical** to its pre-refactor lines — proven per symbol with
   `../../shared/includes/regression-fence.md` (blob/normalized-diff), not by reading the diff.
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

## Phase 2: Test Handling

Skip for VERIFY_COMPILATION test mode.

### Load Conditional Files

```
Phase 2: testing.md -- READ
Phase 2: test-edge-cases.md -- READ (WRITE_NEW, IMPROVE_TESTS, or CHARACTERIZE_GAP)
```

### Test Mode Execution

**RUN_EXISTING:** Run the existing test suite. Verify all tests pass. This establishes the behavioral baseline. If any test fails, investigate before proceeding -- the refactoring must not start from a broken state. Then record the lock: `prove.characterization = "existing:<test path>:green:<pre-refactor sha7>"` in the CONTRACT — the commit gate blocks on a missing/`not_run` value in every test mode.

**CHARACTERIZE_GAP:** The existing test does not exercise every unit being moved (`coverage_gap > 0`). Close the gap BEFORE any production edit:
1. For **each** uncovered unit in `uncovered_units`, write a characterization (pin-down) test that executes it with a representative input and asserts on real output — mount/render the component, or call the function, with a payload that reaches actual logic (not an empty-state/early-return path). Source representative inputs from existing fixtures, sample data, or recover them from git history (e.g. `git show <sha>:<path>`) when they were deleted; never invent shapes the code never sees.
   - The bar is "fails loudly if behavior changes," not full Q1-Q25. A smoke test that mounts the unit and asserts `does not throw` + a stable output snapshot is the minimum; prefer a value assertion where the unit returns something checkable.
   - A parameterized table over the units (one case per unit) is the canonical shape for SPLIT_FILE / GOD_CLASS.
2. Run the new tests against the **pre-refactor** code and confirm they pass. This is the lock — they must be green on the OLD code, or they are not characterizing current behavior. If a unit genuinely cannot be exercised (truly dead), record it in the contract as `dead:<unit>` with evidence and exclude it from the move; do not silently skip it.
   - **When the unit does not exist yet (SPLIT / EXTRACT that CREATES it), the lock as written is
     unsatisfiable** — the test cannot import a symbol that has no pre-refactor definition, and
     that ambiguity has stalled real runs. It is not a licence to skip the lock. Satisfy it the
     equivalent way: write the characterization test against the **extracted** unit, and assert
     outputs that match the inline pre-refactor behaviour verbatim — which is checkable, because
     the extracted body must be byte-identical to the moved lines (prove that with
     `../../shared/includes/regression-fence.md`, do not assert it). Record
     `prove.characterization = "extracted-identical:<pre-refactor sha7>:<N>u:<test path>"` so the
     variant is visible in telemetry rather than hidden behind the same string as a true
     green-on-old lock.
   - This variant is ONLY for units the refactor creates by moving existing lines. A unit whose
     body is rewritten, merged, or newly authored is not byte-identical to anything, so it has no
     pre-refactor behaviour to characterize — that is `WRITE_NEW` plus a behaviour decision, and
     claiming `extracted-identical` for it is a false lock.
3. Apply Q1-Q25 self-eval on the new tests. Only after `coverage_gap` reaches 0 (every moved unit now exercised, or proven dead) does execution proceed.
4. Record `test_audit_after` with the closed gap, **and record the characterization LOCK in the CONTRACT `prove` block NOW — before any production edit**: `prove.characterization = "green:<pre-refactor sha7>:<N>u:<test path>"` — a STRING (like the other prove fields) naming the pre-refactor SHA the pin-down tests were green against, the unit count, and the test path, with `coverage_gap: 0`. The Prove step is not only blind_audit + adversarial recorded at commit time — the characterization lock is the FIRST proof and belongs in the CONTRACT the moment tests are green on the old code (between green tests and the move), not backfilled at commit. **This is a gated artifact, not advice: the `refactor-safety-gate` hook and the completion self-check both BLOCK on a missing/`not_run` `prove.characterization`** (added after the 2026-07-09 skill-eval run proved prose alone gets skipped).

**VERIFY_MOVE:** No characterization authoring — the proof is that nothing changed. Execute in this
order, BEFORE the move and again after: (1) declare the regression fence over the units being moved
and the barrel path; (2) run the consumer suites and record the green baseline SHA; (3) do the move;
(4) re-prove byte identity per symbol, re-run the cycle check, re-run the consumer suites. Record
`prove.characterization = "verify-move:<pre-refactor sha7>:<N>u:<consumer suite path>"` at step 2 —
same timing rule as every other mode, before the first production edit, never backfilled. If step 4
shows any symbol whose bytes moved, the tier was wrong: revert, re-route to CHARACTERIZE_GAP, and
say so in the run log rather than downgrading the claim in place.

**WRITE_NEW:** Write tests for the target file before refactoring. The tests capture the current behavior so that the refactoring can be verified against them. Apply Q1-Q25 self-eval on the new tests. Same coverage bar as CHARACTERIZE_GAP: every unit being moved must be exercised, not just the file's entry point. **Same LOCK recording as CHARACTERIZE_GAP step 4** — the moment the new suite is green on the PRE-refactor code, write `prove.characterization = "green:<pre-refactor sha7>:<N>u:<test path>"` into the CONTRACT, BEFORE any move edit (the commit gate blocks without it; this mode is where the 2026-07-09 eval caught the backfill gap).

**IMPROVE_TESTS:** When the refactoring type is IMPROVE_TESTS (target is a test file):
1. Run Q1-Q25 self-eval on the existing tests to identify gaps
2. Classify gaps and plan improvements
3. Execute structural cleanup first, then assertion strengthening
4. Re-score -- gate: improvement of at least 2 points (or reach 16+/25)

### Test Results Display

Show the test results, then proceed to execution. No approval gate.

---

## Phase 3: Execution + Post-Audit + Adversarial Review

### Backup Branch (FULL mode)

Create a backup branch before making changes:

```bash
git checkout -b backup/refactor-[target]-[date]
git checkout -  # return to original branch
```

### Execute Refactoring

Record `PRE_REFACTOR_SHA = $(git rev-parse HEAD)` at the start of Phase 3, before any changes.

Apply the planned changes according to the extraction list, following these rules:

1. One extraction at a time. Verify tests pass after each extraction before starting the next. "Tests pass" here means a test that **actually exercises the extracted unit** — guaranteed by the Phase 2 coverage gate, which has already characterized every moved unit. If you reach an extraction whose unit has no exercising test, stop and go back to CHARACTERIZE_GAP; do not lean on build/type-check to wave it through.
2. Update all imports affected by each extraction (use the Dependency Mapper results).
3. Maintain behavioral equivalence -- the refactored code must produce identical outputs for identical inputs.
4. Follow CQ patterns from `cq-patterns.md` in all new code.
5. Respect file size limits throughout. If an extraction creates a file that exceeds the limit, split further.
6. **Leaves first, entry file last.** For a multi-file split, create every leaf module BEFORE
   rewiring anything. New leaves are unreferenced until wired, so the repo keeps compiling with the
   original entry file fully intact — then the entry file becomes ONE switch-over edit. The failure
   this prevents is specific: half-rewired imports when a run is interrupted (context compaction, a
   killed session, a timeout) leave a tree that neither builds nor reverts cleanly. Ordering the work
   this way makes every intermediate state a valid one.

**Behavioral equivalence is scoped to the MOVE, not the whole run.** Rule 3 means the *extraction/move* produces identical outputs — that is what the unchanged-tests-still-pass proof certifies. It does NOT mean "any bug you discover stays in the file." Bugs surfaced by the audits below are fixed in **Phase 3.5 (Bug Remediation)** within this same run, as a SEPARATE commit. A refactor that tidies a file but leaves its bugs is half a job — it forces a second pass over the same code later. "I must preserve behavior, so I'll backlog the bug" is the exact rationalization to avoid: preserve behavior in commit 1, fix the bug in commit 2, same session.

**Type-specific CodeSift tools (when available):**

| Refactor type | CodeSift tool | Use |
|---------------|--------------|-----|
| RENAME_MOVE | `rename_symbol(repo, old_name, new_name)` | LSP-based cross-file rename. Fallback: manual edit with grep. |
| BREAK_CIRCULAR | `find_circular_deps(repo)` before + after | Verify cycles are broken. Fallback: skip verification. |
| Any (post-execution) | `find_unused_imports(repo, file_pattern=SCOPE)` | Clean stale imports. Fallback: skip. |

### Failure Recovery

| Failure | Action |
|---------|--------|
| tsc/type-check fails | Fix type errors. Retry up to 3 times. If still failing: revert current extraction, mark in contract as BLOCKED, proceed to next extraction (GOD_CLASS) or stop (single extraction). |
| Tests fail after extraction | Revert to `LAST_PASSING_SHA` (updated after each successful extraction commit). Re-analyze: was the extraction incorrect, or does the test need updating? If test is testing internal implementation (not behavior): update test. If extraction broke behavior: revert extraction and try a different approach. |
| Lint fails | Fix lint issues. This should never block — lint is auto-fixable in most cases. |
| Adversarial CRITICAL | Fix immediately. Re-run adversarial on the fix. Max 2 iterations. |
| All verifications fail | Restore from backup branch. Mark contract as BLOCKED. Report to user. |

### Split-File Audit Rule

**After any refactoring that creates new files:** Run CQ self-eval on EACH extracted module, not just the orchestrator. The bugs move with the code. CQ failures (CQ5, CQ8, CQ9, CQ17, CQ19) live in the modules where the actual logic resides.

1. List the files to audit = the **scope-fence** files, INCLUDING the new modules this split created. A split EXTENDS its own scope-fence to the files it extracts — those new modules are in-fence by definition, so "audit every extracted module" and "stay inside the scope-fence" are the SAME set, not a contradiction. A file modified OUTSIDE the scope-fence is a fence VIOLATION to surface (backlog / ask), never an extra audit-and-ship target.
2. Run CQ1-CQ40 self-eval on EACH of those scope-fence files (orchestrator + every extracted module — the bugs move with the code)
3. Any CQ critical gate failure (CQ3/4/5/6/8/14 = 0) in ANY module blocks the commit — **when the failure is in code this refactor moved, touched, or created**. A PRE-EXISTING critical failure confined to UNTOUCHED units of an in-fence file (e.g. CQ8 in `persist()` while you extract `calculateTax`) is NOT a commit-blocker: it is identical before and after the diff, fixing it usually needs its own characterization tests + product decisions, and blocking on it would make incremental extraction of legacy god-files impossible. Disposition: verify it is byte-identical pre/post (no regression), disclose it loudly in the post-audit (`pre-existing, out-of-fence-unit`), and backlog it per Phase 3.5/Phase 4 — never silently, never as an excuse for a failure your diff introduced. (Both 2026-07-09 skill-eval executors independently hit this ambiguity and resolved it this way; this paragraph makes that the written rule.)

### CodeSift Post-Audit Verification (when CodeSift available)

After execution completes, stage all scope-fence files (`git add [specific files]`) first, then run:
```
review_diff(repo, since=PRE_REFACTOR_SHA, until="STAGED",
            checks="breaking-changes,test-gaps,dead-code,complexity,blast-radius",
            token_budget=10000)
impact_analysis(repo, since=PRE_REFACTOR_SHA)
changed_symbols(repo, since=PRE_REFACTOR_SHA)
diff_outline(repo, since=PRE_REFACTOR_SHA)
```

- **Scope fence:** If `impact_analysis` returns affected files OUTSIDE the scope fence → WARNING: unintended blast radius.
- **Behavioral equivalence:** REMOVED symbol consumed externally → CRITICAL: breaking change. MODIFIED signature → WARNING: verify callers updated.
- **CQ Auditor integration:** Pass `review_diff` output as `machine_checks` input. Auditor uses machine checks as baseline and focuses on domain-specific gates (CQ5, CQ8, CQ9, CQ14, CQ19, CQ25).
- **Boundaries:** If `check_boundaries` rules exist: run `check_boundaries(repo, rules=PROJECT_RULES)`. Otherwise skip.

**CLI-only CodeSift: an empty result is NOT a clean result.** The calls above pass `until="STAGED"`;
the CodeSift *CLI* does not necessarily support comparing against the staged tree. When only the CLI
is available, first determine whether staged comparison is supported. If it is not, do **NOT** fall
back to a commit-only diff command and read its empty output as "no problems found" — the staged
changes were never examined, and an empty answer to the wrong question is the most dangerous
possible input to a safety gate. Instead:

1. Record `machine_checks=degraded:cli-no-staged-diff` (it flows to the CQ Auditor and the report).
2. Refresh the structural index for the changed files (`index_file` per file — not a full re-index).
3. Substitute what the CLI *can* do on staged content: `git diff --staged --check` for whitespace/
   conflict damage, plus symbol-reference scans over the moved/renamed symbols to catch dropped
   consumers.

Never spend a second round trip re-issuing the unsupported form once it has failed.

When CodeSift unavailable: skip machine verification. Pass empty `machine_checks` to CQ Auditor. Log `[DEGRADED: CodeSift unavailable — machine verification skipped]`.

### CQ Post-Audit

Run CQ1-CQ40 on every modified and created file. Print ALL 40 gates per file:

```
CQ POST-AUDIT: order.service.ts (132L)
CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=1
CQ11=1 CQ12=1 CQ13=1 CQ14=1 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=1
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=1 CQ25=1 CQ26=N/A CQ27=1 CQ28=N/A
Score: 24/24 applicable -> PASS
```

Post-audit score must not be lower than pre-audit. Any regression is a bug in the refactoring.

**A tool response is not the audit.** `audit_scan`, `python_audit`, `framework_audit` and friends
answer a handful of checks each; printing their result and calling it `Score: 29/29` claims 29
evaluated gates when five ran. Every gate in the printed line must be one of: `1`/`0` (you
evaluated it), or `N/A` **with a reason** — a gate no tool covered and you did not read for is
neither, so evaluate it or record it as unevaluated and say the audit is partial. Report the
denominator honestly per `../../shared/includes/gate-registry.md`: `score` over the full set,
`applicable_score` over what applied, and never a total larger than what was actually checked.

### Verification

**If running in a secondary worktree, bootstrap dependencies and scope the suite first** — see `env-compat.md` → "Secondary Worktree Bootstrap". A worktree does not inherit `node_modules`; verify the toolchain matches the main checkout, reuse the root install (never a partial package-local one), then scope type-check/tests to the **touched package(s)** (`--filter=<pkg>`). A pre-existing failure in an unrelated package is `pre-existing-out-of-scope`, not a blocker — do not burn the run rediscovering errors that were red before you started.

**When the full suite fails only in files this refactor never touched**, do not silently widen the
fence and do not wave it through either. Do all three: (a) record each failing file and its error,
(b) re-run the SCOPED suite plus type-check/build to show the touched surface is green, (c) re-run
the failing files alone — local parallelism and shared fixtures produce timeout flakes that vanish
when they are not competing. Then report **WARN with that evidence attached**, not PASS. Expand the
scope fence only if the failure reproduces through a dependency path this refactor actually changed
— that makes it a regression, and the fence was wrong. Otherwise it is pre-existing or
environmental, and the honest record says which one and how you told them apart.

Run the verification suite (scoped per above when in a worktree):

1. Type checking (tsc, mypy, or equivalent)
2. Test suite — scoped to touched package(s) in a worktree; full suite in the primary checkout
3. Lint (if configured)
4. CQ self-eval on all modified files
5. Q1-Q25 on all modified test files

> ⛔ **This 5-item suite is NOT the finish line — it is a mid-pipeline checkpoint.** Reaching the end of it does NOT mean the refactor is verified, done, or committable. **There is no "condensed", "light", or "5-step" refactor path in FULL mode** — if you find yourself treating this list as the whole workflow, you are mid-pipeline, not done. The Independent CQ Auditor (blind audit, next section), the CQ1-CQ40 pre/post audit, and the Adversarial Review are part of the SAME non-optional sequence. Do **not** commit-as-done, do **not** report `COMPLETE`, and **never** defer the blind audit or adversarial review to a "user decision" / "awaiting approval" — they are HARD GATES that run automatically without asking. A refactor that stopped here is **BLOCKED, not done** (see Completion Gate Check).

### Independent CQ Auditor (FULL mode — HARD GATE, non-skippable, default tier, read-only)

After the lead's post-audit, dispatch an independent CQ Auditor agent. Run CQ1-CQ40 independently on ALL modified/created files. Does NOT trust the lead's scores. Catches N/A abuse and rubber-stamped gates.

**This is a HARD GATE, not best-effort.** The lead's own CQ post-audit is NOT a substitute — the whole point is a second, independent pass that never sees the lead's scores. In FULL mode (single and batch), the run CANNOT reach `COMPLETE`/PASS without it. Allowed telemetry values for `blind_audit` are `clean:strict` or `clean:degraded[:<reason>]` (findings applied or deferred) — the optional `:<reason>` suffix (`:no-machine-checks` when CodeSift is offline, `:same-model` under a single-agent lock) records *why* it was degraded and is still a PASS value, just lower-confidence; it never blocks on its own. **`skipped` and `not_run` are pipeline FAILURES, not neutral states** — if the auditor genuinely cannot be dispatched in this environment, mark the run `BLOCKED` and say so loudly; never claim PASS/WARN with the blind audit absent. A self-rolled lighter pass reported as "done" is forbidden — run the real independent pass or report BLOCKED.

**CodeSift availability does NOT gate the auditor.** The auditor is an LLM agent that reads the full source + CQ checklist itself; CodeSift only enriches the optional `machine_checks` input. When CodeSift is unavailable, pass empty `machine_checks` and record `blind_audit: clean:degraded:no-machine-checks` — **but still RUN it.** "CodeSift unavailable" is never a reason to skip the blind audit. (This is the exact regression seen in the field: `codesift:unavailable` was being conflated with `blind_audit:skipped`.)

**Single-agent-lock environments (Codex): run the auditor role INLINE, do not BLOCK.** Where the harness forbids sub-agent dispatch (Codex's single-agent lock — see `env-compat.md`), "cannot dispatch a separate agent" is NOT the "cannot run it at all" case above. Run the CQ Auditor role inline as a distinct blind pass: re-read the full source against the CQ1-CQ40 checklist WITHOUT consulting the lead's scores, and record `blind_audit: clean:degraded:same-model` (a distinct marker from the CodeSift-offline `clean:degraded:no-machine-checks` case, so downstream can tell weaker same-model independence apart from a merely un-enriched cross-model run). Cross-model independence is then carried by the adversarial-review gate below **when rotation selects a different model family** — so under the single-agent lock, ensure the rotation pool includes a provider outside the orchestrator's own family; if it cannot, record `adversarial: …:degraded:same-family` rather than implying independence that did not happen. `BLOCKED` is reserved for when neither an inline nor a dispatched blind pass can run at all — the single-agent lock is not that case.

**Input:** Full source of each file, CQ checklist, CQ patterns, tech stack, `machine_checks` from CodeSift (if available).

The **orchestrator** applies FIX-NOW items in Phase 3.5 (as the separate fix commit). Only items whose fix needs files OUTSIDE the scope fence, or that require a behavior/product decision the user declined, go to the backlog — deferral is a fix-SCOPE decision, never a severity or size one.

### Adversarial Review (MANDATORY — do NOT skip)

**Risk-sensitive mode selection:**
- Default: `--mode code`
- If diff touches auth, payment, crypto, PII, or migration files: `--mode security`

**Staging:** Stage ONLY files within the scope fence — not `git add -u` (which misses new files and may include unrelated changes):
```bash
git add [specific files from scope fence]
```

**Iterative review with `--rotate`:** Run adversarial passes sequentially, one random provider per pass. Each pass sees the FIXED code from previous passes — so fixes themselves get reviewed. A pass that returns 0 new findings ends the loop **only when the ledger completion scan (below) is also clean** — an empty pass alone never ends it if an open CRITICAL identity remains.

**Finding-disposition ledger (`zuvo/contracts/<id>-findings.json`) — carry dispositions across rotated passes.** Each pass runs a *different* random provider that never saw what earlier passes already resolved, so without a ledger a preserved-verbatim, out-of-fence, or decision-deferred item is re-reported every pass: the loop never reaches the 0-findings early exit and burns its pass budget re-litigating settled dispositions.

**The orchestrator owns this ledger — providers never write it.** A provider only reports findings in its own words; the orchestrator normalizes each into one ledger row. That single rule dissolves the identity/duplicate problems: providers never mint fingerprints, so there is exactly ONE identity per finding. The file is a JSON **array** of rows like the one below; an *identity* is all rows sharing a `fingerprint`, and its state is that group's latest row.

```json
{ "fingerprint": "file|rule-id|signature", "provider": "codex-5.3", "severity": "CRITICAL|WARNING|INFO",
  "evidence": "one line",
  "disposition": "reported|fixed|false-positive|preserved-verbatim|out-of-fence|decision-deferred|reopened|reaffirmed",
  "reaffirms": "<the terminal disposition this row re-asserts; only for disposition=reaffirmed, else dash>",
  "fix_commit": "<sha7-or-dash>", "regression_test": "<path; REQUIRED when disposition=fixed, else dash>" }
```

- **Identity (assigned at ingest, by the orchestrator).** For each finding a provider reports, match it to an existing identity by `file|rule-id|signature`, else by `file|rule-id` + evidence. `signature` = a short normalized excerpt of the issue site (the offending symbol name or expression, whitespace-collapsed and lowercased) — it drifts when the code changes, so it is a matching hint, and `file|rule-id` + the orchestrator's evidence judgment is the fallback key. (This is guidance for an LLM orchestrator, not a byte-exact hash; the fallback path is expected to carry most matches.) Matched → append a row under that identity's **original fingerprint**. Unmatched → a new identity keyed by this fingerprint. A finding keeps ONE fingerprint for its whole life; there is never a second fingerprint to reconcile and no `supersedes` chain to walk.
- **Severity belongs to the IDENTITY, not the row — monotonic MAX, ratchets UP only.** An identity's severity is the highest severity any pass has assigned it: a later pass rating it higher ratchets it UP; **rating it lower NEVER lowers it** (re-rating a CRITICAL identity down to WARNING/INFO on a later row is forbidden). At ingest the orchestrator must preserve the provider's stated severity — it may not record a provider's CRITICAL as a lower severity on the first row. The gate (below) reads the *identity's* severity, never just the latest row's — so no downgraded row can flip a CRITICAL out of the blocking rule. When a severity ratchet lifts a WARNING/INFO identity UP to CRITICAL, any prior non-`fixed` terminal it held (a scope disposition `preserved-verbatim`/`out-of-fence`/`decision-deferred`, OR `false-positive`, which was judged at the lower severity) is no longer legal for it: the identity reverts to open (`reopened`) and must reach `fixed`/`false-positive` — re-judged at CRITICAL severity — before completion.
- **State = the latest row for an identity.** Passes run sequentially (one provider per pass), so append order is a total order and "latest" is unambiguous. `disposition` alone encodes the state: the OPEN states are `reported` (seen, not yet dispositioned) and `reopened` (was resolved, a later pass produced new evidence it persists); every other value is RESOLVED.
- **Resolving reuses the identity's original fingerprint** with `disposition: fixed` (or `false-positive` / a WARNING-only scope disposition) — it is never re-signed from the now-fixed code.
- **Regression vs. spurious re-report — both are LOGGED, never dropped.** When a later pass reports a finding whose identity is already resolved, the orchestrator appends a row (it never silently drops): if the evidence shows the issue STILL PRESENT (the fix did not hold), the row is `reopened` → it becomes the latest → for a CRITICAL it blocks. If there is no new evidence (the provider simply had not been told it was already resolved), the row is `reaffirmed` — it RE-ASSERTS the identity's prior terminal disposition (named in `reaffirms`, whatever it was: `fixed`/`false-positive`, or a WARNING/INFO scope disposition) and inherits that terminal status, with the evidence comparison that justified the call recorded in the row's `evidence` field. So the state stays settled *and* the re-report is auditable. A CRITICAL identity's prior terminal can only ever be `fixed`/`false-positive` (scope dispositions are forbidden for CRITICAL), so a `reaffirmed` CRITICAL necessarily inherits `fixed`/`false-positive` and does NOT block the gate. `reaffirmed` re-asserts a prior resolution; it is valid only on an already-resolved identity and never as a first row.
- **CRITICAL has only two terminal dispositions: `fixed` or `false-positive`.** A CRITICAL may NEVER be `preserved-verbatim` / `out-of-fence` / `decision-deferred` (those are WARNING/INFO-only scope decisions). **Any identity of CRITICAL severity whose latest disposition is other than `fixed`/`false-positive` blocks completion — regardless of pass count or an early 0-findings exit** (a `reaffirmed` latest row counts as the `fixed`/`false-positive` state it inherits, so it does not block). The severity checked is the identity's (its monotonic max, per the rule above), not the latest row's, so a downgraded later row cannot dodge it. `reported` and `reopened` are open states, so an un-remediated or regressed CRITICAL always blocks. This is what keeps the early exit safe: the carry-forward suppresses *re-reporting*, never remediation.
- **The completion scan (run at EVERY terminal path — 0-findings early exit, cap exhaustion, and final verdict).** The loop ends, and the run may claim done, ONLY IF a scan of the ledger shows no CRITICAL-severity identity whose *effective* terminal is outside `{fixed, false-positive}` (for a `reaffirmed` latest row, the effective terminal is the `fixed`/`false-positive` row it inherits). An identity failing that check BLOCKS the run (unsafe) — an empty pass never launders an open CRITICAL, and this scan runs at every terminal path, not just the early-exit one. The `fixed` rows' correctness is NOT re-litigated here: it rides on the machinery the skill already has — Phase 3.5's demonstrated `regression_red` (red→green) proof and the tests-still-pass gate — so the ledger references that proof rather than re-inventing a grade. Whether the run is `strict` or `degraded` is the existing PROVE telemetry's job (below), not a second grading rule in this scan.
- **Over-rated CRITICAL — resolved, never silently downgraded.** If a later assessment judges a CRITICAL was over-rated, it is still resolved the same two ways: `fixed`, or `false-positive` (with the rationale) when the CRITICAL claim itself was unfounded. There is deliberately NO severity-downgrade disposition — a silent downgrade is exactly the laundering vector this gate blocks, so a disputed CRITICAL is dispositioned, not re-rated away.
- **Open WARNING/INFO do NOT block after the pass cap** — they take the normal Phase 4 disposition (fixed in-fence, or backlogged when out-of-fence). This is why the post-cap verification pass may leave fresh WARNINGs unresolved without spinning a new loop.
- **Trust boundary (what the ledger does NOT do).** The ledger is orchestrator-owned bookkeeping; it cannot police the orchestrator's own honesty or blind spots. Its integrity rests on the mechanisms already in this skill, not on self-report: (1) the **Independent CQ Auditor** and the **cross-model rotation** are the check on disposition calls — a mis-judged "spurious" or a fix-introduced defect the orchestrator failed to log is caught when the NEXT independent, different-model pass re-raises it; the ledger feeds those passes, it does not replace them. (2) **The orchestrator MUST NOT silently drop a re-report** — every re-report becomes a row (`reopened` for a regression, `reaffirmed` for a spurious one), per the rule above, so the decision is auditable, never invisible. (3) **A `fixed` disposition REQUIRES a `regression_test`** (mandatory for `fixed`, per the schema; `-` is allowed only for non-`fixed` rows): "fixed" is then backed by a test that goes red on regression at the tests-still-pass gate — mechanical proof independent of the ledger, not the orchestrator's say-so. Where none of these can run (no independent pass, no test possible), the run's PROVE telemetry records the weaker `blind_audit`/`adversarial` `degraded` value and the run cannot claim `strict` — the ledger `disposition` enum is unchanged.
- **The dispositions must ADD UP to the reported count.** `prove.adversarial` records a number
  (`6findings`); the ledger's dispositioned rows for this run must sum to exactly that. If they do
  not, either a finding was dropped without a disposition or the count was copied from a different
  pass — both are silent, and both look identical to a clean run. Count by REPORTED OCCURRENCE (a
  finding raised in two passes counts twice, matching what `prove.adversarial` saw); when duplicates
  recur, additionally report the unique root-cause total, because "6 findings, 2 root causes" and
  "6 independent findings" are very different runs and the single number cannot distinguish them.
- This is a companion to the run CONTRACT (`zuvo/contracts/<id>.json`), same directory and lifecycle — not a new state location.
- **Enforcement model & known limits (disclosed, not hidden).** These per-row rules are **agent-followed guidance**, not hook-validated: the deterministic `refactor-safety-gate` hook enforces only the COARSE contract (`prove.blind_audit`, `prove.adversarial`, `findings_disposition`) — it does not parse this ledger row-by-row. So the ledger's integrity has exactly three backstops, and no more: (1) the **independent cross-model rotation + CQ auditor** re-derive findings without trusting the ledger — a mis-judged `false-positive`, a spurious→`reaffirmed` that was really a regression, or two distinct bugs fuzzy-matched into one identity are caught when a different-model pass raises the surviving defect on the actual code (the ledger feeds these passes but is not their source of truth); (2) a `fixed` row's **`regression_test`** goes red at the tests-still-pass gate if the fix regresses — mechanical, ledger-independent; (3) `ACCEPTED_FINDINGS` suppresses *re-listing* a settled item but a provider may always raise it **with new evidence**, so suppression narrows re-litigation without blinding the next pass to a real defect. What this does NOT give: byte-exact identity matching (it is LLM judgment with a `file|rule-id`+evidence fallback), write-time schema validation, cognitive independence for the single-agent-lock *inline* auditor (same context — hence `degraded:same-model`; the cross-model rotation, not the inline pass, is the real independence check), or any guarantee against an orchestrator that is both dishonest AND faces a same-model-only provider pool — that residual is the reason the blind audit and cross-model rotation exist and are themselves HARD GATES. The `degraded` marker is keyed to which providers ACTUALLY ran (not merely the pool's composition): if no cross-family pass in fact executed, the run records `degraded:same-family` and cannot claim `strict`. Record `degraded` telemetry (never `strict`) whenever a backstop cannot run. **When BOTH independence backstops degrade at once — a same-model inline CQ auditor AND a same-family-only adversarial pass — zero independent verification actually occurred; the run records `degraded:no-independent-verification` (never `strict`), and its report must state plainly that no independent eyes reviewed it.** This is disclosure within the existing `strict`/`degraded` telemetry model, not a new verdict enum. ("HARD GATE" for the blind audit and cross-model rotation means the pass must RUN — *absent* is BLOCKED; running *degraded* satisfies the gate but caps the grade at `degraded`, and whether a fully-degraded run is shippable is then the coarse gate's / reviewer's policy call, not something the ledger invents.) **Regression-proof enforcement is run-level, not per-identity:** the mechanically-enforced floor is Phase 3.5's `prove.regression_red` + the tests-still-pass gate, which the coarse hook reads; the ledger's per-row `regression_test` is a finer-grained *record*, not an independently-enforced check, so a multi-CRITICAL fix relies on that run-level proof covering all of its fixes — a bounded, pre-existing limit of the skill's regression machinery, not a hole this ledger introduces. And the residual the cross-model rotation exists to catch is not only re-report misjudgements but a **first-pass omission** — a real defect the orchestrator never logged at all; that is why the independent, different-model pass reads the actual code rather than trusting the ledger's row set.

**The same disclosure applies to `prove.characterization` and `prove.regression_red`, which
have NO independent check at all.** `blind_audit` and `adversarial` are at least corroborated by a
separate agent/provider that never saw the orchestrator's scores; the characterization and
regression-red fields are written by the SAME agent doing the refactor, from its own claim to have
run the suite, and the commit hook only verifies the string is non-empty and non-sentinel. Record
them as falsifiable evidence (commit sha + test path + counts), never as a bare assertion — that
is what makes a later audit able to catch a fabrication.

**ACCEPTED_FINDINGS carry-forward.** Before each pass after the first, prepend the latest RESOLVED row of each identity to the adversarial input as an `ACCEPTED_FINDINGS` block (fingerprint + disposition + the one-line reason) and instruct the provider: **a settled disposition is not a finding — do not re-report it.** If the provider believes a listed item is wrong, it must say so **with new evidence** — and a **higher-severity assessment counts as new evidence** (a later pass arguing a settled WARNING is really CRITICAL reopens it for re-rating; this is the only way the severity ratchet fires on an already-dispositioned identity, so ACCEPTED_FINDINGS suppression can never freeze a mis-rated CRITICAL as a settled WARNING). The orchestrator treats such a re-report as the regression path above and appends a `reopened` row for that one identity, at the escalated severity. This makes the 0-findings early exit reachable and ends the unbounded clean-check loop **without weakening remediation** — a real, un-dispositioned bug is still a finding, a regressed CRITICAL re-opens and blocks, and every CRITICAL must still reach `fixed`/`false-positive`.

**Context-enriched input:** Prepend refactoring context + full source files so the provider can verify behavioral equivalence, not just diff syntax:

```bash
(echo "CONTEXT: refactor [TYPE] [TARGET] scope:[N files]";
 echo "CQ-PRE: [pre-audit score]. CQ-POST: [post-audit score]. Critical: [gates]";
 echo "SCOPE-FENCE: [file list]";
 echo "MOVED_VERBATIM: [files PROVEN byte-identical to PRE_REFACTOR_SHA — see regression-fence.md; assert the list only after the check passes]. Focus on new/changed logic. Verbatim-moved code is out of scope unless the move itself creates an issue.";
 echo "---NEW/MODIFIED FILES---";
 cat [each new or modified PRODUCTION file in scope fence];   # NOT the test files — see below
 echo "---TESTS: [N] characterization tests green on <pre-refactor sha7>, [M] existing suites pass---";
 echo "---FACADE + COLLABORATORS (SPLIT/EXTRACT only)---";
 cat [the composing facade]; sed -n '1,80p' [each direct collaborator];
 echo "---ORIGINAL SOURCE (excerpt-capped)---";
 head -c 40000 [target file before refactoring];
 echo "---DIFF---";
 git diff --staged) | ~/.zuvo/adversarial-review --rotate --mode [code|security]
```

**Measure the payload BEFORE dispatch, do not discover the cap by being truncated.** Pipe the
assembled input through `wc -c` first. The wrapper caps at 30K (code/test) and truncates silently
enough that a pass which never saw the highest-risk file is indistinguishable from a clean one:

```bash
SIZE=$(…assembly… | wc -c)
[ "$SIZE" -gt 28000 ] && echo "SPLIT REQUIRED: ${SIZE}c"
```

Over the cap, split **by extracted responsibility** — one pass per extracted module, each carrying
only the ORIGINAL segment that module came from — rather than letting the tail fall off. Aggregate
the findings across passes; a file that received no pass is not reviewed, and saying so is
mandatory (`../../shared/includes/cross-provider-review.md`).

**Tests are summarized, not pasted.** `cat`-ing a large characterization suite displaces the
production files the review exists to look at — the promised context gets evicted by the very
tests that prove it works. Send the one-line green summary above instead. Same for lockfiles and
generated output.

**SPLIT/EXTRACT must carry the facade.** When behaviour is assembled across files, a module-only
prompt makes reviewers report that fields, guards or gates "disappeared" — they were reattached
one layer up, in the composing facade the prompt omitted. Include the facade in full and the first
~80 lines (signatures) of each direct collaborator. This is the single largest source of
false-positive findings in split refactors.

The provider receives: (1) every new/modified in-fence file in full — placed FIRST so provider truncation can never drop the files under review, (2) the original file (excerpt-capped) — can check nothing was lost in extraction, (3) diff — sees exact changes. This prevents false positives on moved-verbatim code while catching real issues like dropped branches, changed signatures, or broken re-exports.

**DELETE_DEAD reviews:** prepend the verified production caller count and the zero-consumer evidence to the CONTEXT line, plus `UNTOUCHED_NOT_REPLACEMENT: <symbol> (<reason>)` for any name-similar unit the plan deliberately leaves alone. Reviewers flag only behavior removed from a LIVE path. Proposals to port or implement never-wired behavior are feature gaps (backlog), and documented-but-unmounted behavior is documentation drift (backlog) — neither is a refactor regression nor an in-fence blocker unless the staged deletion changes current runtime behavior.

If `adversarial-review` is not in PATH: `~/.zuvo/adversarial-review` (stable; the versioned cache path breaks after any release)

**Preflight the providers ONCE, before the first dispatch.** Run discovery a single time
(`~/.zuvo/adversarial-review --doctor`, or the first pass's provider list). If NO provider is reachable,
record `adversarial: blocked:no-provider` and go straight to the independent local CQ/security
pass — do **not** retry the dispatch per pass. Repeated zero-output attempts against an unreachable
provider are the most common way a refactor burns its budget without producing a single finding,
and the outcome is identical after the first attempt. `blocked:no-provider` is an honest degraded
state that must appear in the report; it is NOT `clean`.

**Fallback order when a provider is down** — follow it in order, stop at the first that works, and
record which step produced the pass. Guessing at this per-run is where the trial-and-error goes:

| # | Try | Record as |
|---|-----|-----------|
| 1 | Another provider in the pool, different model family | `clean`/`Nfindings` (full strength) |
| 2 | Another provider, SAME family as the orchestrator | `…:degraded:same-family` |
| 3 | The orchestrator itself, inline, as a blind second pass on the diff alone | `…:degraded:same-model` |
| 4 | Nothing reachable | `blocked:no-provider` + the local CQ/security pass |

Steps 2-4 are progressively weaker independence, and each has its own marker precisely so the
report cannot present them as the same thing. Never skip to step 4 because step 1 failed once —
`--doctor` tells you which providers are actually reachable, so the choice is a lookup, not a
search. An auth failure is cached for the run (`adversarial-review.sh` remembers it), so trying the
next provider costs one dispatch, not another full timeout.

**Pass count by diff size:**

| Diff size | Max passes | Rationale |
|-----------|-----------|-----------|
| < 50 lines | 2 | Small extraction — quick sanity check |
| 50-200 lines | 3 | Standard refactor — most issues found in 2-3 passes |
| > 200 lines or GOD_CLASS | 4 | Large split — fixes on fixes need full depth |

**Remediation review MUST pass `--rotate`.** The wrapper's default `MULTI_MODE` is empty, which
means *auto: multi if 2+ providers are available* — so omitting `--rotate` on a fix-verification
pass silently fans out to EVERY configured provider in parallel, producing duplicate findings for
one small diff and burning the budget the cap exists to protect. Bounded verification is one
provider per pass, by construction.

**Convergence at the pass cap (the last pass is never the finish line for a CRITICAL).** The cap bounds *review* effort, not *remediation*. If the LAST permitted pass surfaces a CRITICAL, apply the fix and run ONE verification-only pass beyond the cap. That pass may ONLY confirm the CRITICAL is gone and (via the ledger) that the fix introduced nothing new — it may **not** open a new remediation loop for fresh WARNINGs. **Non-CRITICAL findings on the last pass do NOT earn an extra pass.** When the final permitted pass
returns only WARNING/INFO: apply every in-fence mechanical fix, run the focused tests, record each
disposition in the ledger, and stop. Spending another full rotated pass to re-confirm a set of
one-line fixes is the loop this cap exists to end — the ledger already records what was done, and
the tests already prove it. The extra pass is reserved for the CRITICAL case below, where the
question is whether a *safety* claim still holds.

If a CRITICAL is still unresolved after that verification pass, **or the verification pass surfaces a NEW CRITICAL** (introduced by the fix or otherwise), that CRITICAL counts as unresolved and the run is **BLOCKED (unsafe), not "shipped at cap"** — do not spin another fix loop past the cap. An unfixed CRITICAL blocks completion no matter how many passes were spent.

**Per-pass fix policy (disposition by fix-SCOPE, never by line count):**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING — real bug, one clearly-correct fix** | Fix it in Phase 3.5 (the fix commit). **Size is irrelevant** — a 40-line mechanical bug is still fix-now. Never park a bug just because the fix is large. |
| **WARNING — needs a behavior/product DECISION** (e.g. on total failure: partial result vs hard error) | Not a bug, a choice. Interactive → ask the user (Phase 3.5 decision gate, ≤1 question). Batch/`--auto`/`no-pause` → pick the safe default, log `[DECISION-DEFAULT: …]`, surface in report. |
| **WARNING — fix needs files OUTSIDE the scope fence** | Backlog with file:line — genuinely out of this contract's reach. |
| **INFO** | Known concerns (max 3, one line each). |
| **0 findings** | Early exit — stop passes, code is clean. |

The old "WARNING > 10 lines → backlog" rule is gone: line count is not a proxy for scope. A big mechanical fix is still a fix; a one-line product decision is still a decision.

**Meta-review:** If pass 1 returns 0 findings AND diff_lines > 150: add false-negative warning — large diffs with zero findings suggest insufficient review depth. Run pass 2 regardless. (`diff_lines` = the sum from `git diff --staged --numstat`, computed BEFORE prompt enrichment — never derived from reviewer input or prompt line count.)

Do NOT discard findings based on confidence alone. "Pre-existing" is NOT a reason to skip — if the issue is in a file you are editing, fix it now.

**Boundary/security findings: trace one layer OUT and one layer IN before classifying.** A provider
reviewing a service file in isolation cannot see the guards around it, so it reliably reports
"missing rate limiting", "unbounded input", "no auth check", "missing uniqueness" on code where the
router already validates and the schema already constrains. Before dispositioning such a finding:

- **One layer outward** — the router/middleware: is the input already validated, authenticated,
  size-capped, or rate-limited before it reaches this function?
- **One layer inward** — persistence: does a NOT NULL / UNIQUE / CHECK constraint or transaction
  already enforce the invariant the finding says is missing?

Dismiss ONLY when a layer enforces **the specific invariant the finding names**, on **every** path
that reaches this code — a guard that validates a different field, or that sits on one of three
routes (plus a queue consumer and a CLI entry point) mounting the same service, is not enforcement.
`grep` the call sites before concluding "the router handles it". When that holds, the finding is a
false positive — record it as such **with the citation** (`router.ts:42 validates`, `schema.sql:17
UNIQUE`), not as a bare dismissal. Partial enforcement is a REAL finding, narrowed to the unguarded
paths. If neither layer enforces it, it is real and in scope. This check is what separates "the reviewer lacked context" from "the
guard is genuinely absent" — and citing the enforcing line is what stops the next pass re-raising it.

---

## Phase 3.5: Bug Remediation + Commit (in-process — leave the file CORRECT, not just tidier)

The point of a refactor is that the file ends up **better AND correct**, in one sitting — not tidier-but-still-buggy, forcing you back into the same code later. So real bugs surfaced by the CQ auditor and adversarial passes are fixed HERE, in this run. The behavior-preserving guarantee is kept via **stacked commits inside the one run**, not by deferring the fix: commit 1 proves the move changed nothing; commit 2 is the fix. One process for the user; clean, bisectable history underneath.

This phase OWNS all committing (Phase 4 no longer commits — it records).

**Disposition (the line is fix-SCOPE, not severity or size):**

| Finding | Disposition |
|---------|-------------|
| Real bug, one clearly-correct fix (any size) | **Fix now** (commit 2). Mechanical correctness has one answer — don't park it. |
| Real bug, fix needs files OUTSIDE the scope fence | Backlog with file:line — genuinely out of this contract's reach. |
| Behavior/product DECISION (partial vs hard error on failure; swallow vs surface a cost; etc.) | **Not a bug — a choice.** Interactive: ask the user (≤1 question), apply the chosen fix into commit 2. Batch/`--auto`/`no-pause`: pick the safe, conservative default, log `[DECISION-DEFAULT: …]`, surface in the report; backlog only if the user later declines. |

**Before applying the FIRST fix, size its blast radius.** When a finding changes the *error*,
*validation*, or *authorization* behaviour of an **exported** symbol, the fix is a contract change,
not a local repair: every production caller and every HTTP/RPC boundary that reaches it inherits
the new behaviour. Enumerate them (`find_references` + a route/handler trace, or grep for the
symbol and its route path) BEFORE editing, and then either add those files to the scope fence or
disposition each one explicitly in the ledger. Doing this after the fix means the next adversarial
pass raises the callers you did not look at, and the run spends a whole extra pass on it. Fixes
that stay inside the symbol — a wrong constant, a missing null-guard, a swapped argument — do not
need this.

**Draft-only / unwired parity repairs.** A repair that only brings a path with **no live consumers**
up to parity with the wired path has no live behaviour to regress, so a red-on-pre-fix regression
test is unsatisfiable by construction. This is a narrow carve-out, not a way around step 3c: it
applies only when the path's zero-consumer status is PROVEN with the same evidence DELETE_DEAD
requires (symbol references + repo-wide import/re-export/dynamic/string-literal search), and it is
recorded, not skipped — `prove.regression_red = "n/a-unreachable:<evidence>"`. The gate accepts that
value (it is not empty/`skipped`/`not_run`) and it stays visible in telemetry. If ANY consumer
exists, or you cannot prove none does, the demonstrated red is required as normal.

**Procedure:**

0. **Record the Prove step in the CONTRACT — BEFORE you commit (the external gate reads it).** After the blind audit + adversarial passes (Phase 3), write their outcomes into the contract's `prove`: `prove.blind_audit` = the blind-audit telemetry (`clean:strict` / `clean:degraded` / `fix:N`, never `skipped`/`not_run`); `prove.adversarial` = `clean` / `Nfindings` / `Nfindings:preserved`. **Both record what the pass
FOUND, not how the run ended.** An audit that surfaced four bugs you then fixed stays `fix:4` — do
not rewrite it to `clean:strict` because the tree is clean now. The completion state lives in
`findings_disposition` and `cq_after`; overwriting the audit value erases the only record that the
gate caught anything, and makes a run that needed remediation indistinguishable from one that never
had a finding. The `refactor-safety-gate` hook reads these on `git commit` — if either is still `skipped`/`not_run`/empty and the staged files are in this refactor's scope fence, the commit is **rejected**. That is the bind: you literally cannot commit a refactor whose Prove step you skipped.
1. **Commit the pure refactor (always).** Stage scope-fence files → `git commit -m "refactor([scope]): [what moved]"`. This is the behavior-preserving proof: the Phase-2 characterization/existing tests, UNCHANGED, still pass. Record `REFACTOR_SHA`. (no-commit mode: show the diff + message, don't commit.)
   If adversarial passes recorded findings destined for fix-now, set `findings_disposition = "stacked-correction-pending"` BEFORE this commit — a transition value the gate accepts (it is not empty/`pending`/`unresolved` and does not contain `fix`, so `regression_red` is not demanded yet); after the demonstrated red in step 3, replace it with `fixed:<N>`. If any fix was already applied to the working tree during Phase 3 passes ("CRITICAL — fix immediately"), separate it out (stash, or stage move-hunks only) so THIS commit is the pure move; the fix hunks land in commit 2.
2. **Triage** the CQ-auditor + adversarial findings into the table above.
3. **If fix-now items exist:**
   a. Apply every fix-now fix.
   b. Behavior now CHANGES, so update the characterization test that pinned the OLD (buggy) behavior to assert the NEW correct behavior, and add a regression test that is **red on `REFACTOR_SHA`, green on the fix**.
   c. **DEMONSTRATE the red — a logical implication is not proof.** Run the NEW assertions
      against the PRE-fix code with a real tool call and capture the failing output (e.g.
      `git stash`/`git show REFACTOR_SHA:<file>` into a scratch copy, or a `/tmp` runner
      importing the pre-fix module), then run them against the fixed code and capture the
      pass. "The old test asserted +20 and passed, so -20 would have failed" is the exact
      inference two consecutive skill-eval runs (2026-07-10) showed agents substituting for
      the actual red run — and one of those runs even logged a self-contradictory 'RED'
      entry. Record the proof in the CONTRACT NOW:
      `prove.regression_red = "red@<REFACTOR_SHA7>:green@<fix-verify>:<test path>"` —
      the commit gate BLOCKS the fix commit when fix-now items were applied but
      `prove.regression_red` is missing/`not_run` (runs with NO fix-now items set nothing;
      the gate keys on the disposition containing a fix).
   d. Re-verify: type-check + **targeted suite** (touched package/files, compared against the session baseline — a test that was red before the correction or broken by the local env is `pre-existing-out-of-scope`, recorded, NOT a blocker; the FULL suite runs once at the end per the targeted-tests rule) + ONE adversarial pass over the fix diff (`~/.zuvo/adversarial-review --mode code`) — must converge (no new CRITICAL).
   e. **Commit separately:** `git commit -m "fix([scope]): [bug summary]"` (`feat`/`perf` if that fits better). NEVER fold the fix into the refactor commit — that erases the move-vs-change boundary that makes commit 1 trustworthy.
   Else: print `[REMEDIATION: none — no fixable bugs surfaced]`.
4. **Decisions:** resolve per the table (ask / safe-default+log). Out-of-scope-fence items → backlog (Phase 4).

**Why two commits and not one:** a single mixed commit can't be bisected — if prod breaks you can't tell "moved the code" from "changed the logic." Two commits in one run cost you nothing and keep that boundary. (If you genuinely want one commit, that's the only thing to override here — the in-run fixing stays either way.)

---

## Phase 3.6: Test Quality Gate (zuvo:test-audit → tier A)

The Phase 2/3 Q1-Q25 evals are self-scored, and field runs still shipped weak tests. After the
Phase 3.5 commits — behavior is now proven and locked, so improving tests can no longer break the
characterization proof — run the gate from `../../shared/includes/test-quality-gate.md` with:

- `TEST_SCOPE` = every test file this refactor **created or modified** (characterization/pin-down
  suites, updated specs) PLUS every **pre-existing** test file covering an in-fence production
  file (Phase 1 Test Discovery already found these — reuse `test_audit_before.test_file`).
- `FIX_COMMIT_PREFIX` = `test(<scope>):`

The include dispatches the REAL `Skill(zuvo:test-audit …)` on that scope, fixes every file below
tier A in-run (separate `test:` commit, suites re-run green), re-audits (max 2 iterations), and
prints `[GATE: test-quality] PASS|WARN|N/A` with the on-disk `zuvo/audits/` report path as proof
of dispatch. Record `prove.test_quality = "<PASS|WARN|N/A>:<worst tier>:<report path>"` in the
CONTRACT. Below-A after the cap → WARN + per-file backlog, never silence. Skip only in
`plan-only` / VERIFY_COMPILATION runs (nothing test-shaped happened) — and say so.

---

## Phase 4: Completion

### Commits (recorded — committing happened in Phase 3.5)

Phase 3.5 has already committed: the pure refactor (`REFACTOR_SHA`), and — when fix-now bugs existed — a separate `fix(…)` commit. Record BOTH SHAs in the contract and the Post-Completion Summary. If no bugs surfaced, there is just the one refactor commit.

In no-commit mode: Phase 3.5 showed both diffs + proposed messages instead of committing; nothing to record here beyond the proposed messages.

**Telemetry vs commits:** everything Phase 4 writes (CONTRACT, review artifact, backlog, retro, doc notes) is LOCAL telemetry — never stage it into the refactor/fix commits. If the repo tracks these paths, ONE trailing `chore(refactor): telemetry` commit MAY carry them; the `commits` array still lists only the production refactor/fix commits. Expected final `git status`: clean, or dirty only with untracked/ignored telemetry paths — that is the intended end state, not an unfinished run.

### Update Contract State

Mark contract: `"stage": "COMPLETE"`, `"cq_after": { "score": "18/18", "critical_failures": [] }`, `"commits": ["abc1234"]`.

**When any CQ gate is N/A, record BOTH denominators** — a bare `18/18` is ambiguous about whether
eighteen gates were evaluated or eighteen of thirty applied:

```json
"cq_after": { "score": "29/29", "applicable_score": "17/17", "na": 12, "critical_failures": [] }
```

`score` counts every gate in the set (N/A gates score as passing, since a gate that does not apply
cannot fail); `applicable_score` counts only the evaluated ones. The gate is passing when **every
applicable check passes AND every N/A carries its evidence** — an N/A without a stated reason is an
unevaluated gate wearing a passing badge, per the three-state rules in
`../../shared/includes/gate-registry.md`.

### CodeSift Index Update

After committing: `index_file(path=<changed-file>)` for every changed file.

**Do not index a secondary worktree.** Many repo instruction files (this one included) forbid it —
worktree paths pollute the main repo's index with duplicate symbols that then answer later queries
with the wrong file. If repository instructions forbid worktree indexing, or `index_file` is
unavailable, **skip it and record the post-index verification as `degraded:<the exact restriction>`**
rather than reindexing anyway or silently claiming a fresh index. The run still has real evidence
without it — local complexity, cycle checks, and the test suite — so say which of those carried the
verification.

### Backlog Persistence (FULL mode)

Read `../../shared/includes/backlog-protocol.md`. Persist ONLY the items Phase 3.5 deferred — fixes needing files outside the scope fence, and behavior decisions the user declined. **Mechanical bugs were already fixed in Phase 3.5; they do NOT belong in the backlog.** Persist to `memory/backlog.md`. Fingerprint: `file|rule-id|signature`. Source: `zuvo:refactor` or `zuvo:refactor/cq-auditor`. Deduplicate per `backlog-protocol.md`.

**Transactional / concurrency residuals need an atomicity boundary line.** A deferred item like
"read-modify-write race in `applyCredit`" is unactionable months later — the next person re-derives
the whole analysis. When the deferral is an out-of-fence data race, add ONE line naming: (a) the
operations that must share a transaction, (b) the current race window (what interleaving loses or
duplicates data), and (c) the migration/constraint/RPC that would close it (unique index, `SELECT
… FOR UPDATE`, atomic RPC). That keeps the fix cheap to pick up without dragging schema work into
a behavior-preserving refactor.

### Content-keyed review artifact (on success only)

A refactor that completed its in-skill review layer (CQ post-audit + blind audit + adversarial)
has ALREADY reviewed the production files it changed. Record that so the pipeline-entry gates
do not demand a redundant standalone review: write `memory/reviews/<base7>..<head7>-<slug>.md`
with the `range:`/`files:` header per `../../shared/includes/review-artifact.md`, listing the
production files this refactor touched (range head = the refactor/fix commit). Coverage is
content-keyed (by blob), so this only vouches for the exact reviewed content. Skip in no-commit
mode (nothing committed to vouch for).

### Aggregate Review Hand-off (single FULL mode)

A single refactor is fully reviewed by its in-skill layer (CQ post-audit + independent blind audit + adversarial). That layer is scoped to ONE contract's scope fence. When several refactors run back-to-back as separate invocations (a refactor sweep — the common real-world case), nothing reviews their **combined** blast radius: a symbol renamed in refactor A and consumed by refactor B's new module, two extractions that now duplicate each other, a re-export chain broken across several commits.

Do NOT auto-run `zuvo:review` after every single refactor — that is redundant ceremony the in-skill layer already covers. Instead, **detect a series and hand off once.** At completion:

1. Determine the session merge-base from the worktree's own repo: `repo_root=$(git rev-parse --show-toplevel); MERGE_BASE=$(git -C "$repo_root" merge-base HEAD <main-branch>)`. The `<MERGE_BASE>..HEAD` range is content-SHA-portable across worktrees, so the surfaced command diffs correctly from any checkout — a worktree/CWD reset is never a reason to drop the hand-off.
2. Scan `zuvo/contracts/refactor-*.json` for sibling contracts with `stage == "COMPLETE"` whose commits are ahead of `MERGE_BASE` on the current branch (i.e., landed this session, not yet reviewed together).
3. If 2 or more sibling refactor commits exist (including this one), surface:

```
AGGREGATE REVIEW RECOMMENDED
  N refactor commits this session not yet reviewed together: <sha7 list>
  Run: zuvo:review <MERGE_BASE>..HEAD   (cross-refactor integration check)
```

Print this in the Post-Completion Summary. If this refactor was invoked under an orchestrator running a known sweep, the orchestrator SHOULD run that single `zuvo:review` once after the LAST refactor — not after each one. (In `batch <file>` mode the series is known, so this becomes the MANDATORY aggregate review in Batch Completion, not a recommendation.)

### Knowledge Curation

Run `knowledge-curate.md`: `WORK_TYPE = "implementation"`, `CALLER = "zuvo:refactor"`, `REFERENCE = <commit SHA>`.

### Documentation (REQUIRED — no silent skip)

Follow `documentation-mandate.md`. A pure internal refactor with no behavior/API/contract
change is the COMMON case here — but it must still be DECLARED, not silently skipped:
`[DOC: N/A — internal-only refactor, no behavior/API/contract change]`. If the refactor
DID change public surface (moved a module, renamed an exported symbol, split a package,
changed an import path others use) → update the architecture/onboarding note + CHANGELOG.
Record the doc paths (or the N/A line) for the Post-Completion Summary.

### Follow-up ideas (optional — ZERO ceremony, leaves a receipt)

Follow `../../shared/includes/followup-ideas.md` with `<skill> = refactor`: append genuine new
ideas to `memory/ideas.md` at the MAIN checkout root if any surfaced, then ALWAYS record the
receipt `~/.zuvo/log-ideas --skill refactor --count <N>` (N=0 is the normal, honest outcome — do
not invent ideas to inflate it). The receipt makes the un-gated step's silence auditable in
`~/.zuvo/ideas.log` without forcing ideation.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to output.

## Completion Gate Check

**A refactor is BLOCKED until proven COMPLETE — and proof is an ARTIFACT, not a self-assessment.** Each gate below leaves evidence: a file, a telemetry row, a log line. "I did it" / "dependency impact = 0, so I skipped the scanner" / "I went with the condensed flow" without the artifact = it did NOT happen = verdict is `BLOCKED`. This gate runs AFTER the code change, so **if you already committed the code, that commit is provisional** — the run is not finished, and you may not present it as done, until every item below has its artifact. Skipping a HARD GATE because the change "looks small/safe" is exactly the failure this gate exists to catch: triviality is an output of the gates, not an excuse to skip them.

```
COMPLETION GATE CHECK
[ ] Refactor type classified and printed: [RENAME/EXTRACT/SPLIT/INLINE/RESTRUCTURE]
[ ] CQ pre-audit printed on target file (all gates before changes)
[ ] Coverage gate: `units_total`/`units_covered` printed; if gap > 0, characterization tests were written for EVERY uncovered moved unit and ran green on the PRE-refactor code (build/type-check/static-resolution do NOT satisfy this item)
[ ] Characterization LOCK recorded: `prove.characterization` written into the CONTRACT the moment the suite went green on the PRE-refactor code — BEFORE the first move edit, in every test mode (WRITE_NEW/CHARACTERIZE_GAP/RUN_EXISTING), never backfilled at commit time (the refactor-safety-gate hook blocks on a missing value)
[ ] Baseline test suite ran green before first change
[ ] After each change: tests ran and green (not just at the end)
[ ] CQ post-audit printed — score must not regress
[ ] Independent CQ Auditor (blind audit) RAN — telemetry is clean:strict or clean:degraded, NOT skipped/not_run (HARD GATE; if it could not be dispatched the verdict is BLOCKED, never PASS/WARN — CodeSift being unavailable does NOT excuse skipping it)
[ ] Adversarial review ran on final diff
[ ] Bug remediation (Phase 3.5): every fix-now bug fixed + tested IN THIS RUN as a separate fix commit; nothing parked by size; only out-of-scope-fence items or user-declined decisions deferred. If bugs were fixed, the run has 2 commits (refactor, then fix)
[ ] Regression red DEMONSTRATED (only when fix-now items were applied): the new regression assertions were actually RUN against the pre-fix code with the failing output captured — not inferred from the old assertion's flip — and `prove.regression_red` recorded in the CONTRACT (the gate blocks the fix commit without it)
[ ] Test Quality Gate (Phase 3.6) ran: `[GATE: test-quality] PASS|WARN|N/A` printed with a REAL `zuvo/audits/` test-audit report path (inline Q-rescoring is a substituted gate = INVALID); below-A files fixed in-run as a `test:` commit or WARN + per-file backlog; `prove.test_quality` recorded
[ ] Aggregate review hand-off evaluated: if 2+ sibling refactor commits this session, the `zuvo:review <range>` line is surfaced (per Aggregate Review Hand-off)
[ ] Documentation updated if public surface changed, else explicit [DOC: N/A — internal-only] (per documentation-mandate.md)
[ ] Run: line printed and appended to log
```

**Do not conflate three different things** — the verifier separates them, and so must you:
- **SAFETY gates** — blind-audit (Independent CQ Auditor), adversarial review, characterization coverage. These prove the refactor did not break behavior. **Never skippable, never reducible by user scope, never "looks small so I skipped it."** Skipping one = the code is *unsafe* = `BLOCKED`. **Running a gate and then parking its findings is the same failure** — an adversarial pass that surfaces 8 bugs and backlogs them (instead of fixing the in-fence ones in Phase 3.5) is `BLOCKED(unsafe)`, not done. The gate's value is the remediation, not the ceremony of having run it.
- **BUILD SCOPE** — targeted package type-check/tests vs full `turbo build/test --force`. The user *may* legitimately narrow this ("just type-check + targeted tests"), but only if you **declare it**: `[SCOPE: user-reduced — targeted type-check+tests; full build skipped per user]`. Silent narrowing is not allowed; declared narrowing is fine.
- **TELEMETRY** — retro, run-log, CONTRACT, review artifact. These don't make the code safer, but they are the durable PROOF the gates ran and the history the skill improves from (losing them is exactly how months of retros vanished). Cheap; always do them. Missing telemetry ⇒ the run is *unrecorded* (`INCOMPLETE`), not necessarily unsafe — but it is **not done** either.

**Run this verifier verbatim and paste its output — cross-harness (plain shell, no MCP; Claude/Codex/Cursor/Antigravity):**

```bash
# REFACTOR SELF-CHECK — mirrors the external refactor-safety-gate (the real bind).
# Reads the CONTRACT prove fields — the SAME artifact the git hook reads at commit time —
# so this self-check and the hook can never disagree. Single source of truth = the CONTRACT
# (not a global ~/.zuvo log tail, not a commit range; the commit is LAST, gated by the hook).
# Resolve by the Phase-1 target hash — NEVER newest-by-mtime (concurrent/resumed sweeps share the checkout).
# TARGET_HASH is DERIVED HERE from the target path, because a shell variable does not survive
# between phases (it was referenced but never assigned until 2026-08-02 — so every run silently
# took the mtime fallback the line above forbids, and could self-check a DIFFERENT file's contract).
# SUBSTITUTE the literal repo-relative path of the file this run refactored for <TARGET-PATH>
# below — Phase 1 recorded it in the CONTRACT. Leaving the placeholder (or exporting nothing) made
# every run hash the SAME empty string to da39a3ee, which is not a per-target key at all: it either
# hard-BLOCKs every refactor or, if that one file ever exists, validates every run against it.
TARGET="<TARGET-PATH>"
case "$TARGET" in
  "<TARGET-PATH>")
    # placeholder still here = the agent never substituted the path, i.e. the check never ran.
    # That is an ERROR, not a trivial run: exiting 0 here would hand every lazy run a free PASS.
    echo "GATE: BLOCKED — <TARGET-PATH> was never substituted, so this check verified nothing."
    echo "  Replace it with the repo-relative path this run refactored (Phase 1 recorded it),"
    echo "  or set TARGET=\"\" if this genuinely was a trivial/aborted run with no CONTRACT."
    exit 1 ;;
  "")
    echo "GATE: N/A — no target (trivial or aborted refactor: Phase 1 never ran)."
    echo "  If this WAS a real production refactor, that itself is the bug: create the CONTRACT"
    echo "  (Phase 1) and run the pipeline. Do NOT hand-edit this check to make it pass."
    exit 0 ;;
esac
TARGET_HASH=$(printf '%s' "$TARGET" | shasum | cut -c1-8)
C="zuvo/contracts/refactor-${TARGET_HASH}.json"
if [ ! -f "$C" ]; then
  echo "GATE: BLOCKED — no CONTRACT for target '$TARGET' (expected $C)."
  echo "  Do NOT fall back to the newest contract: on a concurrent or resumed sweep that validates"
  echo "  a different file's refactor and prints PASS for work never checked."
  exit 1
fi
if true; then  # CONTRACT resolved for this run's target — evaluate its prove fields
  g=0
  ba=$(sed -n 's/.*"blind_audit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  av=$(sed -n 's/.*"adversarial"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  fd=$(sed -n 's/.*"findings_disposition"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  ch=$(sed -n 's/.*"characterization"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  case "$ch" in skipped|not_run|"") echo "BLOCK(unsafe): prove.characterization='$ch' — record the pin-down lock (tests green on PRE-refactor code, written the moment the suite goes green, BEFORE any move edit) in $C"; g=1 ;; esac
  case "$ba" in skipped|not_run|"") echo "BLOCK(unsafe): prove.blind_audit='$ba' — run the Independent CQ Auditor and record it in $C"; g=1 ;; esac
  case "$av" in skipped|not_run|"") echo "BLOCK(unsafe): prove.adversarial='$av' — run the adversarial review and record it in $C"; g=1 ;; esac
  # regression-red proof required only when a fix was actually applied (disposition names a fix)
  case "$fd" in *fix*)
    rr=$(sed -n 's/.*"regression_red"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
    case "$rr" in skipped|not_run|"") echo "BLOCK(unsafe): prove.regression_red='$rr' — a fix was applied (disposition='$fd'); DEMONSTRATE the regression test red on the pre-fix code (run it, capture the fail) and record it in $C"; g=1 ;; esac ;;
  esac
  # findings parked? adversarial recorded N>0 findings (not ':preserved') but disposition unresolved
  case "$av" in *findings) case "$fd" in pending|unresolved|"") echo "BLOCK(unsafe): prove.adversarial='$av' but findings_disposition='$fd' — FIX the in-fence bugs in Phase 3.5 (or document each as out-of-fence/declined/false-positive/preserved). 'Moved verbatim' / 'infra was down' are NOT valid defers."; g=1 ;; esac ;; esac
  [ "$g" = 0 ] \
    && echo "GATE: PASS — CONTRACT prove complete (blind_audit=$ba adversarial=$av disposition=$fd); the refactor-safety hook will allow the commit." \
    || echo "GATE: BLOCKED(unsafe) — resolve the BLOCK lines above (RUN the gate / FIX the findings). The git hook will reject the commit until prove is complete; never relabel BLOCKED→PASS, never park a HARD GATE as 'awaiting user decision'."
fi
```

This self-check reads the CONTRACT — the SAME `prove` fields the external `refactor-safety-gate` hook reads on `git commit`. So if the self-check says `BLOCKED(unsafe)`, the hook will reject the commit too; they cannot disagree. `BLOCKED(unsafe)` → run the missing safety gate (or fix the parked findings) and record it in the CONTRACT; never relabel `BLOCKED→PASS`, never park a HARD GATE as "awaiting user decision." `GATE: N/A` is only for a genuinely trivial/aborted run with no CONTRACT — for a real production refactor, no CONTRACT is itself the bug. Only `GATE: PASS` is `COMPLETE`. (This whole gate exists because in one day five field refactors failed: three skipped the SAFETY gates and self-reported done; a fourth ran them but skipped telemetry; a fifth ran adversarial, surfaced 8 production bugs incl. 2 CRITICAL races, and **backlogged all of them** — the worst case, gate ran and verdict discarded. Prose said MANDATORY in 24 places and was ignored; the external hook is what finally makes it true.)

### Post-Completion Summary

```
REFACTORING COMPLETE
------------------------------------
Type: [TYPE] | Target: [filename]
Files modified: [N] | Files created: [N]
CQ: [before] -> [after] | Tests: [status] | Commits: refactor [sha7][ + fix [sha7] (N bugs fixed in-run)]

Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
------------------------------------
```

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion. Printing the markdown retro section without executing the bash leaves all three log files empty.

Field hints — VERDICT: PASS/WARN/FAIL/BLOCKED/ABORTED. CQ: post-audit score. Q: test score or `-`. TASKS: files modified+created. DURATION: phase reached (e.g., `phase-3`). NOTES: type + target (max 80 chars).

---

## Batch Mode (batch <file>)

The full batch-mode protocol — queue parse/triage + PriorityScore ordering, the per-file
pipeline, zero-stop overrides, the anti-rationalization gate, the mandatory aggregate review,
and batch completion — lives in `../../shared/includes/refactor-reference.md` -> "Batch Mode".
Load it when `$ARGUMENTS` begins with `batch`. The same Definition of Done + external commit-gate
apply to every file; per-file Prove is recorded in each file's CONTRACT before its commit.

## GOD_CLASS Protocol

When GOD_CLASS is detected (>600L, 5+ responsibilities):

1. **Identify:** List public methods grouped by responsibility. Map internal dependencies. Extract the group with the FEWEST internal dependencies first.
2. **Decompose iteratively:** For each responsibility: create new module, delegate from original, update imports, run tests, verify equivalence, commit. Repeat until original is under size limit with single responsibility.
3. **Size gate:** After each extraction check original file, new module, and all modules (CQ self-eval via Split-File Audit Rule). Continue if any exceeds limit.

---
