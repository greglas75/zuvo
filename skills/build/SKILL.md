---
name: build
description: "Scoped feature development for changes spanning 1-5 production files. Auto-tiers to LIGHT/STANDARD/DEEP based on risk signals. Flags: --auto (skip plan approval), --auto-commit (commit without confirmation), --tag (create rollback tag)."
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols           # find similar implementations to mirror
    - get_symbol
    - get_symbols
    - get_file_outline
    - find_references          # who would I break by adding this
    - get_context_bundle       # symbol + neighbors in one call
    - search_text              # convention discovery
    - search_patterns          # follow project conventions
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
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

# zuvo:build — Scoped Feature Development

A tiered workflow for implementing new features with bounded scope. Ceremony scales with risk: a 2-file utility addition runs LIGHT (no agents, no auditors), while a service touching auth runs DEEP (parallel analysis agents + independent auditors).

**Scope:** Features affecting 1-5 production files. Test files, backlog entries, and run-log do not count toward the file limit.
**Out of scope:** Bug investigation (`zuvo:debug`), structural reorganization (`zuvo:refactor`), code review (`zuvo:review`), multi-file features with unclear scope (`zuvo:brainstorm` pipeline).

**Scope expansion:** If implementation reveals that the feature requires >5 production files, STOP. Ask the user: continue as build (with justification) or escalate to `zuvo:brainstorm`? Structural splits (extracting helpers to respect file-limits.md thresholds) may auto-expand up to +2 production files without asking. Beyond +2, ask the user.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `--auto` | Auto-approve the implementation plan (skip Phase 2 user confirmation) |
| `--auto-commit` | Commit staged changes without asking (skip Phase 4 confirmation) |
| `--tag` | Create a `build-YYYY-MM-DD-slug` rollback tag after commit |
| `--deep` | Force DEEP tier regardless of file count or risk signals |
| _(remaining text)_ | The feature description |

Flags can be combined: `zuvo:build add CSV export --auto --auto-commit --tag`

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

**Interaction behavior is governed entirely by env-compat.md.** This skill does not override env-compat defaults. Specifically:
- Plan approval and commit confirmation follow env-compat rules for the detected environment.
- `--auto` and `--auto-commit` flags are additive overrides on top of env-compat defaults (they loosen, never tighten).

**Agent dispatch model:** This skill uses **inline prompt dispatch** (see env-compat.md). Agent instructions are embedded in Phase 1b and Phase 4.1 — there are no separate `agents/*.md` files for build.

## CodeSift Integration

CodeSift setup completed in PHASE 0. Use CodeSift tools for all discovery and analysis when available.

## Mandatory File Reading

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../shared/includes/codesift-setup.md              -- [READ | MISSING -> STOP]
  2. ../../shared/includes/no-pause-protocol.md           -- [READ | MISSING -> WARN] (HARD: no mid-loop pauses)
  3. ../../shared/includes/acceptance-proof-protocol.md   -- [READ | MISSING -> STOP] (HARD: per-step proof gates)
```

These files are loaded before reading the task spec and target files.

### PHASE 0.5 — Classify (after reading task context, determine tier)

After CodeSift setup, read the task spec and target files. Classify the build into a tier using the Risk Signals and Tiering Model below.

Print: `[CLASSIFIED] Tier: {TIER}`

### PHASE 1 — Conditional Load (based on tier)

| Include | LIGHT | STANDARD | DEEP |
|---------|-------|----------|------|
| `../../rules/cq-patterns.md` | Full | Full | Full |
| `../../rules/file-limits.md` | Full | Full | Full |
| `../../shared/includes/code-contract.md` | **SKIP** | Full | Full |
| `../../rules/testing.md` | Full | Full | Full |
| `../../rules/test-quality-rules.md` | **SKIP** | Full | Full |
| `../../rules/cq-checklist.md` | **SKIP** | **SKIP** | Full |
| `../../shared/includes/test-contract.md` | **SKIP** | Full | Full |
| `../../shared/includes/quality-gates.md` | **SKIP** | **SKIP** | Q1-Q19 section only |

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file]
```

### DEFERRED — Load at completion

```
  ../../shared/includes/run-logger.md        -- [READ at final step]
  ../../shared/includes/retrospective.md     -- [READ at final step]
  ../../shared/includes/knowledge-prime.md   -- [READ at start if available | MISSING -> degraded]
  ../../shared/includes/knowledge-curate.md  -- [READ at final step if available | MISSING -> degraded]
```

**If any PHASE 0 file missing:** STOP. The plugin installation is incomplete.

---

## Tiering Model

After Phase 0 context gathering, classify the build into a tier. The tier determines how much ceremony runs.

### Risk Signals

Check for these in the feature description and target files:

```
[ ] Touches auth, authorization, or access control
[ ] Touches payment, billing, or money calculations
[ ] Touches database schema or migrations
[ ] Touches a shared utility imported by 5+ files
[ ] Touches API contracts (request/response shapes)
[ ] Target file is a git churn hotspot (top 10 in last 90 days)
[ ] Feature involves concurrency or race conditions
[ ] Touches UI / user-interactive surface (.tsx / .vue / .svelte / .astro / *.css in components/ or app/)
```

### Tier Assignment

| Condition | Tier |
|-----------|------|
| 1-2 production files, 0 risk signals | **LIGHT** |
| 3-5 production files, OR 1 risk signal | **STANDARD** |
| 2+ risk signals (any file count) | **DEEP** |

**Forced DEEP** (regardless of file count or other signals):
- `--deep` flag
- Touches auth/authorization AND any other risk signal
- Touches payment/money AND any other risk signal
- Touches database schema or migrations
- Feature involves concurrency or race conditions

**Cap at LIGHT:**
- Config-only changes (env vars, CI, Dockerfile) with no production code

### Tier Capabilities

| Capability | LIGHT | STANDARD | DEEP |
|-----------|-------|----------|------|
| Discovery pass (Phase 1a) | Yes | Yes | Yes |
| Analysis agents (Phase 1b) | No | Blast Radius agent + inline duplication check | Blast Radius + Duplication Scanner agents |
| Implementation plan | Inline, brief | Full plan with all sections | Full plan with all sections |
| CQ self-eval (CQ1-CQ29) | Critical gates only | Full CQ1-CQ29 | Full CQ1-CQ29 |
| Test quality self-eval (Q1-Q19) | Inline check | Full Q1-Q19 | Full Q1-Q19 |
| Pre-write code contract | No | Yes | Yes |
| Pre-write test contract | No | Yes | Yes |
| Independent CQ Auditor agent | No | No | Yes |
| Independent Test Auditor agent | No | Yes (when dispatch available) | Yes |
| Verification commands | Tests + types (if checker exists) | Tests + types | Tests + types + lint |

Print the tier after assignment:

```
BUILD TIER: STANDARD (3 files, 1 risk signal: shared utility)
```

---

## Phase 0: Project Context

1. Read the project's `CLAUDE.md` and any rules directory for conventions
2. Detect the tech stack from config files (`package.json`, `tsconfig.json`, `pyproject.toml`, etc.)
3. If the stack triggers a conditional rule file (TypeScript, React, NestJS, Python), read it from `../../rules/`
4. Read `memory/backlog.md` if it exists — check for open items related to the feature area
5. **Knowledge Prime:** Run the knowledge prime protocol from `knowledge-prime.md`:
   ```
   WORK_TYPE = "implementation"
   WORK_KEYWORDS = <3-5 keywords from the user's request>
   WORK_FILES = <files that will be touched, if known from step 1-4>
   ```

Output:
```
STACK: [language/framework] | RUNNER: [test runner]
BACKLOG: [N related open items | "none"]
```

Assign the build tier (see Tiering Model above).

---

## Phase 1: Analysis

Analysis runs in two steps. Step 1a always runs. Step 1b runs only for STANDARD and DEEP.

### Phase 1a: Discovery Pass (all tiers)

Before any agent dispatch, establish the scope manually:

1. **Identify candidate files.** From the feature description, list the production files that will be created or modified. Be specific — file paths, not vague areas.
2. **Quick dependency check.** For each candidate file that already exists, run one of:
   - CodeSift: `find_references(repo, symbol_name)` for key exports
   - Fallback: `grep` for import statements referencing the file
3. **Hotspot detection.** Check if candidate files are churn hotspots (top 10 most-changed files in the project over the last 90 days):
   - CodeSift: `analyze_hotspots(repo, since_days=90)` — flag any candidate in the top 10
   - Fallback: run `git log --name-only --format="" --since="90 days ago" | sort | uniq -c | sort -rn | head -20` to get the project-wide top 20 by commit count, then check if any candidate file appears in that list
4. **Risk signal scan.** Check the candidate files against the risk signals list (including hotspot results from step 3). Update the tier if signals change.

Output:
```
DISCOVERY
  Candidate files: [list with paths]
  Surface(s): [backend-logic | api | db | db-data | ui | integration | config | docs — one per file or "mixed"]
  Key dependencies: [files that import/call candidates]
  Risk signals: [updated list]
  Tier: [confirmed or adjusted]
```

The Surface(s) line drives proof shape selection in Phase 2 — see `acceptance-proof-protocol.md`. UI surface activates browser-tool requirement at Phase 4 verification. Backend / api / db surfaces require deterministic proofs (real call, real query) not just unit tests.

This output feeds Phase 1b agents with concrete scope. No guessing.

### Phase 1b: Targeted Analysis (STANDARD and DEEP only)

Dispatch agents with the concrete scope from Phase 1a. In environments without parallel dispatch, run sequentially.

#### Blast Radius Mapper (STANDARD + DEEP)

```
Dispatch with:
  type: Explore
  model: Sonnet
  run_in_background: true (if supported)

  prompt:
  "Analyze the blast radius for changes to these specific files.

  FEATURE: {description}
  TARGET FILES: {candidate files from Phase 1a}
  KNOWN DEPENDENTS: {dependencies from Phase 1a}
  PROJECT ROOT: {working directory}

  Tasks:
  1. For each target file, trace all importers and callers (use impact_analysis if CodeSift available, otherwise grep imports).
  2. Flag any widely-imported module (5+ importers) as high-risk.
  3. Check if any target is a shared utility, type definition, or config.
  4. List test files that exercise the target files.

  Output:
  BLAST RADIUS REPORT
  Files analyzed: [N]
  Direct dependents: [file:symbol list]
  Test coverage: [which targets have tests, which don't]
  High-risk: [widely-imported or shared files]
  Recommendation: [what to test extra carefully]"
```

#### Inline Duplication Check (STANDARD only)

No agent dispatch. The lead performs a quick overlap search during Phase 1b:

1. For each new function/component/service planned, run:
   - CodeSift: `search_symbols(repo, "{name}", include_source=true, detail_level="compact")` + `codebase_retrieval(repo, queries=[{type:"semantic", query:"{what this function does}"}])`
   - Fallback: `grep -rn "{name}\|{synonym}"` with `--include` matching the detected stack extensions (e.g., `*.ts *.tsx` for TypeScript, `*.py` for Python, `*.go` for Go, `*.java` for Java — use the extensions from Phase 0 stack detection)
2. If any match has >70% name or purpose overlap, flag it as a reuse candidate.
3. Include results in Phase 2 plan section "4. Duplication Check" (not "N/A").

This is lighter than the DEEP agent but catches the most common case: AI rewriting an existing helper.

#### Existing Code Scanner (DEEP only)

```
Dispatch with:
  type: Explore
  model: Haiku
  run_in_background: true (if supported)

  prompt:
  "Search for existing code that overlaps with the planned feature.

  FEATURE: {description}
  CANDIDATE FILES: {from Phase 1a}
  PLANNED NEW EXPORTS: {functions/components/services to create — from discovery}
  PROJECT ROOT: {working directory}

  Tasks:
  1. For each planned export, search for existing implementations with similar names or purposes.
  2. Check utility files, shared helpers, and library wrappers for reusable logic.
  3. Search for similar patterns in other modules.

  Output:
  DUPLICATION SCAN REPORT
  Items checked: [N]
  Overlaps: [file:symbol with similarity description]
  Reuse candidates: [existing code to extend]
  Recommendation: [reuse X, extend Y, build Z from scratch]"
```

### Incorporating Agent Results

If agents run in background, proceed to Phase 2 and merge their findings when they complete. If running inline, wait before planning.

---

## Phase 2: Implementation Plan

### LIGHT tier

No formal plan document. Print a brief inline summary:

```
PLAN (LIGHT)
  Files: [list]
  Changes: [1-2 sentences per file]
  Tests: [which test files to create/modify]
```

Proceed unless the user objects (or `--auto` is set).

### STANDARD and DEEP tiers

If `EnterPlanMode` is available, use it. Otherwise, present the plan as a markdown block and wait for user confirmation (unless `--auto` was passed or env-compat auto-approves).

Required sections:

```
## 1. Feature Summary
[1-2 sentences: what and why]

## 2. Scope Fence
PRODUCTION FILES: [exact list — these count toward the 1-5 limit]
TEST FILES: [list — excluded from limit]
FORBIDDEN: files outside these lists, unrelated improvements, opportunistic refactoring

## 3. Blast Radius
[From Blast Radius Mapper, or Phase 1a discovery if STANDARD without agent yet]

## 4. Duplication Check
[From inline check (STANDARD) or Existing Code Scanner agent (DEEP)]

## 5. Implementation Steps
[Ordered list with file paths and what changes in each]

## 6. Test Strategy
- Code types: [function / component / endpoint / hook / service]
- Test files: [paths]
- Critical scenarios: [error paths, edge cases, boundaries]

## 7. Acceptance Proofs
[For each user-observable behavior this build delivers, one entry. See ../../shared/includes/acceptance-proof-protocol.md for surface taxonomy and proof shapes.]
- AP1 — [single declarative sentence describing the behavior]
  - Surface: [backend-logic | api | db | db-data | ui | integration | config | docs]
  - Proof: [exact procedure — command, HTTP call, DB query, browser interaction]
  - Expected: [exit code, response shape, DOM state, screenshot match]
  - Artifact: `.zuvo/proofs/build-<short-slug>-AP1.<ext>`
- AP2 — ...

[For configuration-only or pure-refactor builds with no user-observable behavior change, write "Not applicable — pure refactor / config; behavior unchanged" with one-line justification.]

## 8. Whole-feature Smoke
[If this build contributes to a multi-step user flow that other builds also touch, name the smoke proof here. For self-contained 1-5 file builds, usually skipped — note "Not applicable — self-contained scope". For UI builds touching the same screen as backend builds, mandatory.]

## 9. File Size Check
[Current line count + estimated post-change count for each file to modify]
[Flag any that will exceed limits from file-limits.md]

## 10. Open Questions
[Genuine uncertainties. Empty if none.]
```

If section 10 is non-empty: ask the user (max 4 questions), wait for answers, update plan.

---

## Phase 3: Implement

### 3.1 Pre-Flight

Before writing code, verify:
- Analysis results incorporated (if agents still running, note "pending" sections)
- Scope fence defined
- No file will exceed size limits (plan splits if needed)

### 3.2 Write Code

Implement per the plan.

**STANDARD and DEEP tiers — Pre-Write Code Contract (MANDATORY):**

Before writing each production file, read `../../shared/includes/code-contract.md` and fill the complete contract:

1. **INPUTS AND VALIDATION** — every input with validation strategy
2. **ERROR PATHS** — every failure mode with handling strategy and business impact
3. **NULL AND OPTIONAL HANDLING** — every nullable value with explicit guard
4. **RESOURCE MANAGEMENT** — every resource with cleanup and bounding
5. **SECURITY CHECKLIST** — auth, authZ, PII, injection
6. **PATTERN COMPLIANCE** — existing project patterns identified
7. **FUNCTION SIGNATURES** — public API drafted with error conditions

The contract prevents the most common CQ failures (CQ3, CQ8, CQ10, CQ22, CQ25) by catching them BEFORE code is written, not after.

**LIGHT tier:** Skip the formal contract. Critical CQ gates still apply at self-eval time.

Rules:
- Touch only files in the scope fence. If a dependency forces a change outside, log the expansion with justification. Structural splits (file-limits.md thresholds) may auto-expand up to +2 production files; beyond +2, ask the user. Any non-structural expansion requires user approval.
- Follow project conventions from CLAUDE.md and rules directory.
- After each file, check line count against limits. Split immediately if approaching threshold.

### 3.3 Code Quality Self-Evaluation

**LIGHT tier:** Check critical gates only (CQ3, CQ4, CQ5, CQ6, CQ8, CQ14) + any conditional gates activated by context (CQ16/CQ19/CQ20/CQ21/CQ22). Provide evidence for each. Fix any gate = 0.

**STANDARD and DEEP tiers:** Read `../../rules/cq-checklist.md`. Run full CQ1-CQ29 on every production file written or modified. Condensed reference: `../../shared/includes/quality-gates.md`.

- Score each gate (1 = satisfied, 0 = violated, N/A = not applicable)
- Static critical gates: CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 — any = 0 means FIX before tests
- Conditional critical gates: CQ16, CQ19, CQ20, CQ21, CQ22 — activated by code context
- Provide file:function:line evidence for every critical gate scored as 1
- If >60% gates are N/A, justify each N/A individually

Fix all critical gate violations before writing tests.

### 3.4 Write Tests

Read `../../rules/testing.md` before writing tests. For STANDARD+, also read `../../rules/test-quality-rules.md`.

**STANDARD and DEEP tiers — Pre-Write Test Contract (MANDATORY):**

Before writing tests for each production file, read `../../shared/includes/test-contract.md` and fill the complete contract:

1. **BRANCHES** — exhaustive list from production code (every if/else, switch, try/catch, early return)
2. **ERROR PATHS** — every throw/reject/error return with specific type and message
3. **EXPECTED VALUES** — source of every planned assertion (reject implementation-derived values)
4. **MOCK INVENTORY** — every mock with justification
5. **MUTATION TARGETS** — M1-M5 mapped to specific catching tests
6. **TEST OUTLINE** — describe/it structure traced to branches and error paths

The contract prevents weak tests at the source: missing branches, tautological oracles, unnecessary mocks, and shallow error testing.

**LIGHT tier:** Skip the formal contract. Critical Q gates (Q7, Q11, Q13, Q15, Q17) still apply at self-eval time.

Requirements:
- New functions, components, endpoints, and hooks need tests.
- Mock only external boundaries (HTTP, database, email, time, randomness).
- Run the mental mutation check: simulate 5 mutations (negate condition, remove guard, swap operator, change return value, change error type). If no test catches any mutation, add a targeted test.
- Run tests and confirm they pass.

**Test exception policy:** Not every piece of code warrants its own test file. The following are exempt from dedicated tests IF already covered by an integration or higher-level test:
- Thin wrappers that delegate entirely to another function
- Glue code (wiring, configuration, re-exports)
- Type definitions and interfaces (no runtime behavior)
- Simple constants and enums

When claiming an exemption, cite the covering test: `[exempt: covered by integration test in api.test.ts:45]`.

### 3.5 Test Quality Self-Evaluation

**LIGHT tier:** Inline check — verify Q7 (error path — every error-throwing path with specific type+message), Q11 (branches), Q13 (real imports), Q15 (value assertions), Q17 (oracle independence). Fix any = 0.

**STANDARD and DEEP tiers:** Run full Q1-Q19 on every test file. Score threshold: >= 16 = PASS, 10-15 = FIX worst gaps, < 10 = REWRITE. Provide evidence for critical gates (Q7, Q11, Q13, Q15, Q17).

**Anti-Tautology Check (STANDARD+):** After self-eval, run the anti-tautology automation from `rules/testing.md`:
1. Grep for echo patterns (mock-return-echoed-in-assertion)
2. Verify expected value sources (spec-derived, not implementation-derived)
3. Run with `--coverage` if runner supports it — check branch coverage >= 70%

**Independent Test Auditor (STANDARD+ when sub-agent dispatch available):**

Spawn a Test Quality Auditor (Sonnet, Explore) to independently verify Q1-Q19 scores. The auditor receives: production file, test file, and the test contract. Auditor's score wins ties — self-evaluation is biased toward the author.

In single-agent mode: perform the audit as a separate pass with checkpoint: `[CHECKPOINT: switching to independent test auditor role]`.

Proceed to Phase 4 when self-evaluations pass.

---

## Phase 4: Verify

### 4.1 Independent Auditors (DEEP only)

Dispatch two read-only agents in parallel:

#### Test Quality Auditor

```
Dispatch with:
  type: Explore
  model: Sonnet

  prompt:
  "Audit the quality of these test files. Do not trust the lead agent's self-evaluation — read the files yourself.

  TEST FILES: {list}
  CODE TYPE: {function / component / endpoint / hook}

  Tasks:
  1. Read each test file completely.
  2. Run Q1-Q19 evaluation with evidence.
  3. Check for auto-fail patterns: empty bodies, assertions on mock inputs, tests passing with implementation deleted, toBeTruthy on objects.
  4. Report PASS (>= 16, all critical gates), FIX (gaps identified), or BLOCK (< 10).

  Read ../../rules/testing.md and ../../rules/test-quality-rules.md."
```

#### CQ Auditor

```
Dispatch with:
  type: Explore
  model: Sonnet

  prompt:
  "Audit code quality on these production files (entire files, not diffs).

  FILES: {list}
  FEATURE: {description}

  Tasks:
  1. Read each file completely.
  2. Run CQ1-CQ29 with file:function:line evidence.
  3. Classify: FIX-NOW (< 5 min), CRITICAL-BLOCKED (critical gate failure), DEFER (backlog).
  4. Check file sizes against limits.

  Read ../../rules/cq-patterns.md and ../../rules/cq-checklist.md."
```

Handle auditor results:
- **FIX-NOW:** Apply immediately.
- **CRITICAL-BLOCKED:** Fix before commit.
- **DEFER:** Persist to backlog in Phase 4.4.

### 4.2 Verification Commands

Run stack-appropriate checks:

| Tier | Required checks |
|------|----------------|
| LIGHT | Tests + types if a type checker exists (`tsc --noEmit` / `mypy` / `pyright`) |
| STANDARD | Tests + types |
| DEEP | Tests + types + lint |

All must pass. If any fails, fix and re-run.

Read `../../shared/includes/verification-protocol.md` — no completion claims without fresh evidence.

**Verification commands check implementation health (compiles, types, tests). They do NOT check that user-observable behavior matches the AP entries. That is Phase 4.2b.**

### 4.2b Acceptance Proofs (MANDATORY — the behavior gate)

For each AP entry from the Phase 2 plan section 7 (Acceptance Proofs):

1. Set up the AP's preconditions (fixtures, env vars, seeded data, dev server).
2. Run the AP's proof exactly as written:
   - `backend-logic` / `api` / `integration` / `config` — execute shell command or HTTP call. Capture stdout/stderr + exit code to artifact path.
   - `db` / `db-data` — run migration / sample query, capture schema dump or query results to artifact.
   - `ui` — drive Playwright or chrome-devtools MCP through the interaction script. Save screenshot + DOM snapshot to artifact.
   - `docs` — run linter / link checker, capture report.
3. Compare against the AP's `Expected:` field.
4. Verdict per AP: VERIFIED or BROKEN.

**LLM-judge fallback for UI subjective dimensions:** if an AP includes a subjective visual quality the proof cannot deterministically express, after capturing the screenshot dispatch a Sonnet judge with `(AP description, screenshot, DOM)` requiring binary `VERIFIED` / `BROKEN` plus one-sentence justification. Default deterministic.

**Verdict handling:**
- All APs VERIFIED → proceed to 4.3.
- Any AP BROKEN → fix the implementation, re-run from 4.1 (or from 3.2 if the fix is non-trivial). Maximum 3 AP iterations. After 3, abort with `BLOCKED_ACCEPTANCE_PROOF_FAILURE` and surface to user.
- AP marked "Not applicable" in plan → skip with a note. Reason must already be in plan section 7.

**Aggregate scoring forbidden.** Telemetry must report per-file CQ/Q scores (e.g. `cq=27/29@codec.ts,28/29@parser.ts`), never `cq=27/29 aggregate`. The 2026-04-22 codec session shipped Q7=0 and Q11=0 hidden under `q_gates: 19/19 aggregate` — per-file enforcement prevents recurrence.

### 4.3 Execution Checklist

Print before committing. Required items depend on tier.

```
EXECUTION VERIFICATION
----------------------------------------------------
[ALL] [ ] SCOPE: All files match the plan
[ALL] [ ] SCOPE: No unplanned features or refactoring
[ALL] [ ] TESTS: Test suite green
[ALL] [ ] CQ CRITICAL: All critical gates pass (with evidence)
[ALL] [ ] TYPES: Type checker passes (if checker exists; skip with note if none)
[ALL] [ ] AP: Every Acceptance Proof from plan section 7 ran and returned VERIFIED (artifact paths recorded) — or "Not applicable" with reason
[STD+] [ ] CQ FULL: CQ1-CQ29 self-eval, PER-FILE scores + evidence (aggregate forbidden)
[STD+] [ ] Q FULL: Q1-Q19 self-eval on each test file, PER-FILE scores
[STD+] [ ] ANTI-TAUTOLOGY: Automated echo pattern check passed
[STD+] [ ] TEST AUDITOR: Independent auditor score matches self-eval (±1)
[DEEP] [ ] LINT: Linter passes
[DEEP] [ ] CQ AUDITOR: Agent returned, FIX-NOW items applied
[DEEP] [ ] TEST AUDITOR: Agent returned with PASS
----------------------------------------------------
```

### 4.4 Adversarial Review (MANDATORY — do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --mode code
```

If diff touches auth, payment, crypto, PII, or migration files, use `--mode security` instead. If diff touches migrations/schema, use `--mode migrate`.

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** — fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** — known concerns (max 3, one line each).

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this — if true, it's serious."

"Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, add it to backlog with file:line. The adversarial review found a real problem — don't dismiss it just because it existed before your changes.

### 4.5 Backlog Persistence

Collect findings from all sources (self-eval, auditors, verification warnings).

For each item, persist to `memory/backlog.md`:

```markdown
- B-{N} | {file}:{line} | {rule-id} | {description} | seen:1 | confidence:{0-100} | source:build | {date}
```

**Dedup:** If the same `file|rule-id` combo exists, increment `seen:N` and update the date. Do not add a duplicate entry.
**Discard:** If confidence < 25, do not persist. Instead append one line to the build output: `DISCARDED: {file}:{rule-id} — confidence {N}, reason: {why}`.
**Disposition:** Items with confidence 25-50 are tracked. Items with confidence 51+ are actionable.

### 4.6 Stage and Commit

Stage exactly the files created or modified:

```
git add [explicit file list — never -A or .]
```

**Commit:** Follow env-compat interaction rules. `--auto-commit` skips confirmation.

```
git commit -m "build: [feature description]"
```

**Tagging (opt-in):** Only with `--tag` flag:
```
git tag build-[YYYY-MM-DD]-[short-slug]
```

Do not push. Pushing is a separate user decision.

### 4.6 Knowledge Curation

After all work is done (code written, tests passing, CQ/Q scored), run the knowledge curation protocol from `knowledge-curate.md`:

```
WORK_TYPE = "implementation"
CALLER = "zuvo:build"
REFERENCE = <git SHA of the commit>
```

### 4.7 Retrospective (REQUIRED — no opt-out)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.

**The "trivial session" opt-out is removed.** Every build produces a retro entry. If the build truly was uneventful, the entry is brief (one Friction line of `none observed`) but must still exist. The 92% retro skip rate observed in 2026-Q1 left the pipeline blind to its own failure modes.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Tier classified and printed: BUILD TIER: [LIGHT/STANDARD/DEEP]
[ ] Surface(s) recorded in DISCOVERY output
[ ] Code contract filled (STANDARD+) before production code written
[ ] Test contract filled (STANDARD+) before tests written
[ ] CQ self-eval printed with PER-FILE scores and evidence for critical gates (aggregate forbidden)
[ ] Q self-eval printed PER-FILE (>=16 PASS) with evidence
[ ] Adversarial review ran and findings handled
[ ] Acceptance Proofs (Phase 4.2b) — every AP ran and VERIFIED, artifact paths recorded
[ ] All verification commands ran and exited 0
[ ] Retrospective ran (no "trivial session" opt-out)
[ ] Backlog updated with deferred findings or "none"
[ ] Run: line printed and appended to log
```

### 4.8 Output

```
BUILD COMPLETE
----------------------------------------------------
Feature: [description]
Tier: [LIGHT / STANDARD / DEEP]
Files created: [N] | Files modified: [N]
Tests: [N files], all passing
Verification: tests PASS [| types PASS] [| lint PASS]
CQ: [critical gates PASS | score/29 on N files]
Q: [critical gates PASS | score/19 on N test files]
Backlog: [N items persisted | "none"]
Commit: [hash] — [message]
[Tag: [tag name]]

Run: <ISO-8601-Z>\tbuild\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS / WARN / FAIL / BLOCKED / ABORTED only.
CQ: LIGHT → `critical-only`, STANDARD+ → `N/29`.
Q: LIGHT → `critical-only`, STANDARD+ → `N/19`.
TASKS: number of production files created + modified.
DURATION: `light` / `standard` / `deep` (tier label).
NOTES: `[TIER] feature description` (max 80 chars).

Next steps:
  zuvo:review [files]      — independent review
  git push origin [branch] — push when ready
----------------------------------------------------
```

---

## Flag Reference

| Flag | Effect |
|------|--------|
| `--auto` | Skip user approval at Phase 2 |
| `--auto-commit` | Skip commit confirmation at Phase 4.5 |
| `--tag` | Create a rollback tag after commit |
| `--deep` | Force DEEP tier regardless of signals |

Flags are additive. All quality gates run regardless of flags.
