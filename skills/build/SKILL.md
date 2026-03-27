---
name: build
description: "Scoped feature development for changes spanning 1-5 files. Runs parallel analysis agents (blast radius, duplication scan), enforces CQ/Q quality gates, and persists findings to backlog. Flags: --auto (skip plan approval), --auto-commit (commit without confirmation)."
---

# zuvo:build — Scoped Feature Development

A structured workflow for implementing new features with bounded scope. Three analysis agents run in parallel to assess impact and prevent duplication, followed by implementation with mandatory quality self-evaluation.

**Scope:** Features affecting 1-5 files where understanding the blast radius matters.
**Out of scope:** Bug investigation (use `zuvo:debug`), structural reorganization (use `zuvo:refactor`), code review (use `zuvo:review`), multi-file features with unclear scope (use the `zuvo:brainstorm` pipeline).

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `--auto` | Auto-approve the implementation plan (skip Phase 2 user confirmation) |
| `--auto-commit` | Commit staged changes without asking (skip Phase 5 confirmation) |
| _(remaining text)_ | The feature description |

Flags can be combined: `zuvo:build add CSV export --auto --auto-commit`

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Call `ToolSearch(query="codesift")` at skill start. If found, call `list_repos()` once, note the repo identifier. Use CodeSift tools in all subsequent phases. If not found, fall back to Grep/Read/Glob and notify the user once that code exploration will be less thorough.

After editing any file, update the index: `index_file(path="/absolute/path/to/file")`

## Agent Routing

| Agent | Purpose | Model | Type | Phase |
|-------|---------|-------|------|-------|
| Blast Radius Mapper | Trace importers and callers of target files, identify what may break | Sonnet | Explore | 1 (parallel) |
| Existing Code Scanner | Search for overlapping services, helpers, components to prevent duplication | Haiku | Explore | 1 (parallel) |
| Test Quality Auditor | Evaluate test files against Q1-Q17 gates with evidence | Sonnet | Explore | 4 (after tests written) |
| CQ Auditor | Evaluate production files against CQ1-CQ22 with evidence | Sonnet | Explore | 4 (parallel with Test Quality Auditor) |

All agents are read-only (Explore type). They analyze and report; they do not modify files.

## Mandatory File Reading

Before starting work, read each file below using the Read tool. Print the checklist with status. Do not proceed from memory or assume you already know the contents.

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-patterns.md           -- READ/MISSING
  2. {plugin_root}/rules/cq-checklist.md           -- READ/MISSING
  3. {plugin_root}/rules/file-limits.md            -- READ/MISSING
  4. {plugin_root}/rules/testing.md                -- READ/MISSING
  5. {plugin_root}/rules/test-quality-rules.md     -- READ/MISSING
```

Where `{plugin_root}` is resolved per `env-compat.md` (e.g., `CLAUDE_PLUGIN_ROOT` in Claude Code).

**If 1-2 files missing:** Proceed in degraded mode. Note which files are unavailable in the Phase 5 output.
**If 3+ files missing:** Stop. The plugin installation is incomplete.

---

## Phase 0: Project Context

1. Read the project's `CLAUDE.md` and any rules directory for conventions
2. Detect the tech stack from config files (`package.json`, `tsconfig.json`, `pyproject.toml`, etc.)
3. If the stack triggers a conditional rule file (TypeScript, React, NestJS, Python), read it from `{plugin_root}/rules/`
4. Read `memory/backlog.md` if it exists -- check for open items related to the feature area

Output:
```
STACK: [language/framework] | RUNNER: [test runner]
BACKLOG: [N related open items | "none"]
```

---

## Phase 1: Analysis (Parallel Agents)

Dispatch two analysis agents simultaneously. In environments without parallel dispatch, run them sequentially.

### Agent 1: Blast Radius Mapper

Identifies everything that depends on the files you plan to change. Reports which modules, tests, and consumers may be affected.

```
Dispatch with:
  type: Explore
  model: Sonnet
  run_in_background: true (if supported)

  Instructions:
  "Analyze the blast radius for the planned feature changes.

  FEATURE: [description]
  TARGET FILES: [files the feature will create or modify]
  PROJECT ROOT: [working directory]

  Tasks:
  1. For each target file, find all importers and callers (use impact_analysis if CodeSift available, otherwise grep for import statements).
  2. For each caller, note the file path and the specific function/component that depends on the target.
  3. Flag any widely-imported module (5+ importers) as high-risk.
  4. Check if any target file is a shared utility, type definition, or configuration -- these have outsized blast radius.
  5. List all test files that exercise the target files.

  Output format:
  BLAST RADIUS REPORT
  Files analyzed: [N]
  Direct dependents: [list with file:symbol format]
  Test coverage: [which target files have existing tests, which do not]
  High-risk items: [widely-imported modules, shared types, config files]
  Recommendation: [any files that should be modified carefully or tested extra]"
```

**CodeSift tools (when available):**
- `impact_analysis(repo, since="HEAD~1", depth=2)` for dependency graph
- `trace_call_chain(repo, symbol_name, direction="callers", depth=3)` for deep caller chains
- `analyze_complexity(repo, top_n=5, file_pattern=SCOPE)` -- advisory: flag if changes land in an already-complex area
- `analyze_hotspots(repo, since_days=90)` -- advisory: flag if target files are churn hotspots

Complexity and hotspot results are advisory signals, not blockers.

### Agent 2: Existing Code Scanner

Searches the codebase for functionality that overlaps with what you plan to build. Prevents accidental duplication.

```
Dispatch with:
  type: Explore
  model: Haiku
  run_in_background: true (if supported)

  Instructions:
  "Search for existing code that overlaps with the planned feature.

  FEATURE: [description]
  PLANNED NEW CODE: [functions, components, or services you intend to create]
  PROJECT ROOT: [working directory]

  Tasks:
  1. For each planned function/component/service, search for existing implementations with similar names or purposes.
  2. Check utility files, shared helpers, and library wrappers for reusable logic.
  3. Search for similar patterns in other modules (e.g., if building an export feature, check if other export flows exist).
  4. Flag any existing code that could be reused or extended instead of writing from scratch.

  Output format:
  DUPLICATION SCAN REPORT
  Planned items checked: [N]
  Overlaps found: [list with file:symbol and similarity description]
  Reuse candidates: [existing code that could be extended]
  Recommendation: [reuse X, extend Y, safe to build Z from scratch]"
```

**CodeSift tools (when available):**
- `search_symbols(repo, query, include_source=true, file_pattern=SCOPE)` for name-based matches
- `codebase_retrieval(repo, queries=[{type:"semantic", query:"[planned functionality]"}])` for conceptual matches
- `find_clones(repo, min_similarity=0.7)` for copy-paste detection in the target area

### Incorporating Agent Results

If agents run in background, proceed to Phase 2 and merge their findings when they complete. If running inline, wait for both before planning.

---

## Phase 2: Implementation Plan

### Plan Mode

If `EnterPlanMode` is available, use it. Otherwise, present the plan as a markdown block and wait for user confirmation (unless `--auto` flag was passed).

### Required Sections

Every plan must contain all of these sections. A plan missing any section is incomplete.

```
## 1. Feature Summary
[1-2 sentences: what this feature does and why it is needed]

## 2. Scope Fence
ALLOWED: [exact list of files to create or modify]
FORBIDDEN: files outside this list, unrelated improvements, opportunistic refactoring

## 3. Blast Radius
[From Agent 1 -- dependents, high-risk items, test coverage gaps]
[If Agent 1 not yet complete: list known dependents manually, note "pending full scan"]

## 4. Duplication Check
[From Agent 2 -- overlaps found, reuse recommendations]
[If Agent 2 not yet complete: note "pending scan"]

## 5. Implementation Steps
[Ordered list of changes with exact file paths and what changes in each]

## 6. Test Strategy
- Code types being added: [function / component / endpoint / hook / service]
- Test files to create or modify: [paths]
- Critical scenarios: [error paths, edge cases, boundary conditions]
- Quality targets: CQ >= 18/22 (all critical gates pass) + Q >= 14/17

## 7. File Size Check
[For each file to modify: current line count + estimated line count after changes]
[Flag any file that will exceed limits from file-limits.md -- plan a split]

## 8. Open Questions
[Genuine uncertainties about requirements or approach. Leave empty if none.]
```

### Handling Open Questions

If section 8 is non-empty:
1. Present the questions to the user (max 4 at a time)
2. Wait for answers
3. Update the plan based on answers
4. Then proceed

If section 8 is empty, proceed directly.

Wait for user approval before Phase 3 (unless `--auto` flag was passed).

---

## Phase 3: Implement

### 3.1 Pre-Flight

Before writing code, verify:
- Agent 1 and Agent 2 results are incorporated into the plan (if not yet, add now)
- Scope fence is defined
- No file will exceed size limits after changes (plan splits if needed)

### 3.2 Write Code

Implement the feature according to the plan.

Rules:
- Touch only ALLOWED files. If a dependency forces a change outside the scope fence, log the expansion with justification. Structural splits (extracting helpers to respect file limits) auto-expand. Anything else requires user approval.
- Keep business logic in services, not in components or route handlers.
- Follow project conventions from CLAUDE.md and the rules directory.
- After writing each file, check its line count against limits. Split immediately if approaching the threshold.

**When dispatching write sub-agents** (if parallelizing implementation across multiple agents), every agent prompt must include:

```
BEFORE writing code, read these files and follow their rules:
1. {plugin_root}/rules/cq-patterns.md -- NEVER/ALWAYS code pairs, apply during writing
2. {plugin_root}/rules/file-limits.md -- hard size limits (service <=300L, component <=200L, function <=50L)
3. {plugin_root}/rules/cq-checklist.md -- CQ1-CQ22, run self-eval after writing each file

After writing each production file:
- Count lines. If over the type limit from file-limits.md, split now.
- Run CQ1-CQ22 self-eval. Any critical gate = 0 means fix before proceeding.
```

Write agents do not inherit the lead agent's loaded rules. Without explicit read instructions, they produce code without quality constraints.

### 3.3 Code Quality Self-Evaluation

Run CQ1-CQ22 on every production file written or modified. Read `{plugin_root}/rules/cq-checklist.md` for the full protocol.

Condensed reference: `../../shared/includes/quality-gates.md`

- Score each gate individually (1 = satisfied, 0 = violated)
- Static critical gates: CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 -- any = 0 means FAIL
- Conditional critical gates: CQ16 (money), CQ19 (API boundary), CQ20 (dual fields), CQ21 (concurrency), CQ22 (subscriptions) -- activated by code context
- Provide file:function:line evidence for every critical gate scored as 1
- If more than 60% of gates are N/A, justify each N/A individually

**Fix all critical gate violations before writing tests.** Tests should exercise correct patterns, not broken ones.

### 3.4 Write Tests

Write tests per the test strategy from Phase 2.

Requirements:
- Every new function, component, endpoint, and hook must have tests
- Read `{plugin_root}/rules/test-quality-rules.md` for edge case checklist, mock safety rules, and assertion strength standards
- Mock only external boundaries (HTTP, database, email, time, randomness). If a dependency has no side effects, use the real implementation.
- After writing tests, perform the mental mutation check: simulate 5 mutations (negate a condition, remove a guard, swap an operator, change a return value, change an error type). If no test would catch any mutation, add a targeted test.
- Verify expected values come from the specification or reference data, not from copying implementation logic (oracle independence).
- Run tests and confirm they pass.

### 3.5 Test Quality Self-Evaluation

Run Q1-Q17 on every test file written or modified. Read `{plugin_root}/rules/testing.md` for the full protocol.

- Score each gate individually
- Critical gates: Q7, Q11, Q13, Q15, Q17 -- any = 0 means fix before proceeding
- Score threshold: >= 14 = PASS, 9-13 = FIX worst gaps, < 9 = REWRITE
- Provide evidence for every critical gate scored as 1

Proceed to Phase 4 only when both self-evaluations pass (CQ PASS or CONDITIONAL PASS with evidence, and Q >= 14).

---

## Phase 4: Verify

### 4.1 Test Quality Auditor (Agent)

Dispatch a read-only agent to independently verify test quality. This agent reads the actual test files (it does not trust the lead agent's self-evaluation).

```
Dispatch with:
  type: Explore
  model: Sonnet

  Instructions:
  "Audit the quality of the following test files.

  TEST FILES: [list of test files written or modified]
  CODE TYPE: [function / component / endpoint / hook]

  Tasks:
  1. Read each test file completely.
  2. Run Q1-Q17 evaluation with evidence for each gate.
  3. Check for auto-fail patterns: empty test bodies, assertions on mock inputs rather than outputs,
     tests that pass with implementation deleted, toBeTruthy on objects.
  4. Report PASS (>= 14, all critical gates satisfied), FIX (gaps identified), or BLOCK (< 9).

  Read {plugin_root}/rules/testing.md and {plugin_root}/rules/test-quality-rules.md for full criteria."
```

If the auditor returns FIX or BLOCK: address the identified gaps, then re-run the auditor. Do not proceed until PASS or FIX-with-fixes-applied.

### 4.2 CQ Auditor (Agent, parallel with 4.1)

Dispatch a read-only agent to independently verify code quality on the complete production files (not just the diff).

```
Dispatch with:
  type: Explore
  model: Sonnet

  Instructions:
  "Audit the code quality of the following production files.

  FILES: [list of all new or modified production files -- entire files, not diffs]
  FEATURE: [description]

  Tasks:
  1. Read each file completely.
  2. Run CQ1-CQ22 evaluation with file:function:line evidence for every gate.
  3. Classify each finding: FIX-NOW (< 5 min fix), CRITICAL-BLOCKED (critical gate failure), DEFER (backlog).
  4. Check file sizes against limits. Flag any file exceeding its type limit.

  Read {plugin_root}/rules/cq-patterns.md and {plugin_root}/rules/cq-checklist.md for full criteria."
```

Handle results:
- **FIX-NOW items:** Apply immediately
- **CRITICAL-BLOCKED:** Fix before commit (these are critical gate failures)
- **DEFER items:** Persist to backlog in Phase 5

Do not commit until the CQ Auditor has returned.

### 4.3 Verification Commands

Run in parallel (use stack-appropriate commands from Phase 0):

| Check | Command examples |
|-------|-----------------|
| Tests | `npm test` / `pytest` / `vitest run` / `go test ./...` |
| Types | `tsc --noEmit` / `mypy` / `pyright` / `go vet` |
| Lint | `npm run lint` / `ruff check` / `golangci-lint run` |

All must pass. If any fails, fix and re-run.

Read `../../shared/includes/verification-protocol.md` -- no completion claims without fresh evidence.

### 4.4 Execution Checklist

Print this checklist with status before committing. Every item must be satisfied.

```
EXECUTION VERIFICATION
----------------------------------------------------
[ ] SCOPE: All files match the approved plan
[ ] SCOPE: No unplanned features or refactoring
[ ] TESTS: Full test suite green (not just new files)
[ ] TYPES: Type checker passes (or skipped with note)
[ ] FILE LIMITS: All files within size limits (>2x = CQ11 FAIL)
[ ] CQ1-CQ22: Self-eval on entire files, scores + evidence
[ ] CQ AUDITOR: Agent returned, FIX-NOW items applied
[ ] Q1-Q17: Self-eval on each test file, scores + evidence
[ ] TEST AUDITOR: Agent returned with PASS
----------------------------------------------------
```

If any item fails, fix before committing.

---

## Phase 5: Completion

### 5.1 Backlog Persistence

Collect findings from all sources:
1. Test Quality Auditor -- BACKLOG items
2. CQ Auditor -- DEFER items
3. CQ self-eval -- any gate scored 0 that was not fixed
4. Any warnings from verification

For each item, persist to `memory/backlog.md`:
- Fingerprint: `file|rule-id|signature`
- Deduplicate: if fingerprint exists, increment the Seen count. If new, append as `B-{N}`.
- Confidence 0-25: discard (likely false positive)
- Confidence 26-50: track in backlog
- Confidence 51+: report as actionable

Source: `build/{sub-source}`. Zero silent discards.

### 5.2 Stage and Pre-Commit Review

Stage exactly the files created or modified in this build:

```
git add [explicit file list -- never -A or .]
```

### 5.3 Commit

**Default (no flag):** Show the staged file list and proposed commit message. Ask the user to confirm before committing.
**With `--auto-commit`:** Commit without asking.

```
git commit -m "build: [feature description]"
git tag build-[YYYY-MM-DD]-[short-slug]
```

The tag creates a clean rollback point. To undo: `git revert HEAD`.

Do not push. Pushing is a separate user decision.

### 5.4 Output

```
BUILD COMPLETE
----------------------------------------------------
Feature: [description]
Files created: [N]
Files modified: [N]
Tests written: [N], all passing
Verification: tests PASS | types PASS | lint PASS
CQ score: [score]/22 on [N] files
Q score: [score]/17 on [N] test files
Backlog: [N items persisted | "none"]
Commit: [hash] -- [message]
Tag: [tag name]

Next steps:
  zuvo:review [files]     -- verify with independent review agents
  zuvo:docs [path]        -- document the new module
  git push origin [branch] -- push when ready
----------------------------------------------------
```

## Run Log

Log this run to `~/.zuvo/runs.log` per `shared/includes/run-logger.md`:
- SKILL: `build`
- CQ_SCORE: from Phase 3.3 / Phase 4.2 CQ Auditor
- Q_SCORE: from Phase 3.5 / Phase 4.1 Test Quality Auditor
- VERDICT: PASS/WARN/FAIL from Phase 4.4 Execution Checklist
- TASKS: number of files created + modified
- DURATION: `5-phase`
- NOTES: feature description from arguments

---

## Flag Reference

| Flag | Effect |
|------|--------|
| `--auto` | Skip user approval at Phase 2 |
| `--auto-commit` | Skip commit confirmation at Phase 5.3 |

Both can be combined. All agents and quality gates run regardless of flags. Tests must pass.
