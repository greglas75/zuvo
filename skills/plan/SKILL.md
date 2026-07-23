---
name: plan
description: "Analyzes architecture, selects patterns, assesses testability, then decomposes work into ordered TDD tasks with exact verification commands and explicit acceptance mapping. Works from an approved spec (zuvo:brainstorm output) or directly from a user-provided description."
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # architecture overview
    - get_file_outline
    - search_symbols
    - get_symbol
    - find_references          # impact-of-change ahead of decomposition
    - codebase_retrieval       # semantic — testability + similar-pattern questions
    - analyze_complexity       # testability assessment
    - architecture_summary     # high-level project shape
    - search_text
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

# zuvo:plan

Create a detailed, task-by-task implementation plan. Every task follows the TDD protocol: RED (failing test) -> GREEN (minimal code) -> Verify -> Commit.

---

## Input Resolution

Determine the planning input. Two modes: **spec-driven** (from brainstorm output) or **inline** (from user description).

### Step 1: Look for a spec

1. If the user provided an explicit path (e.g., `zuvo:plan docs/specs/my-spec.md`), use that file
2. Otherwise, search: `Glob("docs/specs/*-spec.md")`
3. If multiple specs exist, present the list and ask the user which one to plan against

### Step 2: Determine mode

- **Spec found with `status: Approved`** → **spec-driven mode**. Read spec in full. This is the source of truth.
- **Spec found without `status: Approved`** → Print: "Spec exists but is not approved. Using it as reference in inline mode." Treat spec as context, not authority. → **inline mode**.
- **No spec found** → **inline mode**.

### Inline mode requirements

The user's message (argument to `zuvo:plan`) IS the planning input. Extract:
- **Goal:** what they want built
- **Scope:** which files/areas are affected (explore codebase if not stated)
- **Constraints:** any stated requirements

If the user's description is too vague to plan against (less than one sentence, no clear deliverable), ask ONE clarifying question. Do not block — a couple of sentences is enough to plan from.

Set `planning_mode: "inline"` or `planning_mode: "spec-driven"` — this affects the plan document header and review phase.

---

## Artifact Detection

Check if a plan already exists:

1. `Glob("docs/specs/*-plan.md")` — look for existing plans
2. **Spec-driven mode:** match by `spec_id` field. If a matching plan exists, ask the user whether to revise or start fresh.
3. **Inline mode:** skip this check (no spec_id to match against)
4. If no plan exists, proceed to Phase 1

---

## Mandatory File Loading

### Phase 0 — Bootstrap (load before any work)

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md            -- READ/MISSING
  2. ../../shared/includes/env-compat.md                 -- READ/MISSING
  3. ../../shared/includes/quality-gates.md              -- READ/MISSING
  4. ../../shared/includes/tdd-protocol.md               -- READ/MISSING
  5. ../../shared/includes/session-state.md              -- READ/MISSING
  6. ../../shared/includes/acceptance-proof-protocol.md  -- READ/MISSING
  7. ../../shared/includes/provided-artifact-supremacy.md -- READ/MISSING
  8. ../../rules/file-limits.md                          -- READ/MISSING
  9. ../../shared/includes/run-logger.md                 -- DEFERRED (completion)
 10. ../../shared/includes/retrospective.md              -- DEFERRED (completion)
```

Resolve these paths relative to the currently loaded `skills/plan/SKILL.md`. If a Phase 0 file read fails, mark it as `MISSING`. Deferred files are loaded when their phase begins, not at startup.

### Phase 0.1 — Retro checkpoint marker (run this bash at bootstrap)

Write a run-marker so an abandoned plan is captured at the next zuvo skill
start, and sweep any prior orphans. **Ungated** — never blocks plan.

```bash
# >>> zuvo:retro-marker  (plan Task 7 — passive checkpoint capture)
_RS=$(command -v retro-stub 2>/dev/null || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/retro-stub 2>/dev/null | head -1)
_ZH="${ZUVO_HOME:-$HOME/.zuvo}"
_RSK="${SKILL:-plan}"
_RPR="${PROJECT:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
_RSHA=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
# Sweep PRIOR orphans FIRST — before writing this run's marker — so this
# run's fresh marker is never swept as its own orphan.
[ -n "$_RS" ] && "$_RS" --sweep >/dev/null 2>&1 || true
if mkdir -p "$_ZH/run-markers" 2>/dev/null; then
  { printf 'start_ts=%s\nskill=%s\nproject=%s\nsha7=%s\nbranch=%s\nsession_id=%s\nrepo_root=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_RSK" "$_RPR" "$_RSHA" \
      "$(git branch --show-current 2>/dev/null || echo -)" "${ZUVO_SESSION_ID:-$_RSHA}" \
      "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
      > "$_ZH/run-markers/$_RSK-$_RPR-$_RSHA-$$-$(date +%s).marker"; } 2>/dev/null || true
fi
# <<< zuvo:retro-marker
```

Capture is **best-effort, not guaranteed**: the block is intentionally
ungated (never blocks/fails plan), so if `ZUVO_HOME` is not writable no
marker is written and plan proceeds normally. When a marker *is* written,
`append-runlog` clears it on a clean terminal retro; if plan is abandoned
first, the next skill's `--sweep` emits an ABANDONED stub.

### Phase 0.2 — Arm the stall-recovery watchdog

Follow the **ARM** section of `../../shared/includes/stall-recovery.md` with `skill=plan`: seed
`zuvo/context/plan.heartbeat` (`status: running`, `resume: zuvo:plan`) and — **if `CronCreate` is
available** — arm a `*/3 * * * *` cron tagged `[zuvo-watchdog skill=plan project=…]` that runs
`zuvo-watchdog-check` and re-invokes `zuvo:plan` on a RESUME verdict. This closes the measured gap
where a plan turn killed by an API error sat DEAD for 168 minutes until the user re-prompted
(2026-07-16, rs_be) — the watchdog resumes it in ~3 min. Idempotent (skip if this run's tag is in
`CronList`); if `CronCreate` is absent print the `/loop 3m zuvo:plan` fallback line and continue.
Never block on watchdog setup. **Disarm on clean completion** (right after the run-log append):
write `status: done` to the heartbeat and `CronDelete` the id from its `cron_id:` line (belt:
`CronList` → delete any job whose prompt contains `[zuvo-watchdog skill=plan`).

**If 1-2 files missing:** Proceed in degraded mode. Note which files are unavailable in the final output.
**If 3+ files missing:** Stop. The plugin installation is incomplete.

Execute the CodeSift setup procedure from `codesift-setup.md`. Note the repo identifier for agent dispatches when CodeSift is available.

---

## Provided-Design Check (BEFORE Phase 1 — run even without a brainstorm spec)

Run `provided-artifact-supremacy.md`. `zuvo:plan` is frequently invoked directly on a user-supplied design (a downloaded prototype, `HANDOFF.md`, mockup, "match this 1:1") with NO brainstorm spec — that is the exact case that failed on 2026-05-30. When a design artifact is present:

1. **The artifact is the SOURCE OF TRUTH for WHAT to build; the repo is HOW.** Do NOT downgrade it to "reference-only" and ground the architecture on your own repo reading.
2. **Read it IN FULL**, extract a `## Design Constraints` checklist (DC-1…), quoting every `do not`/`never`/`single`/`one`/`no <X>`/`must`. Carry it into the plan; every architecture decision that touches a DC cites it.
3. **If the artifact contains working code** (`.jsx`/`.tsx`/component files, a runnable prototype) → **inventory and read those files; the plan's tasks PORT them component-by-component into the target stack, not re-derive the behavior from prose.** A 7000-line working prototype is ground truth, not a sketch to reinterpret.
4. Any architecture decision that **contradicts a DC** is a HARD-STOP `[DEVIATION: DC-N says "<quote>" but I propose <X> — confirm]`, never a repo-rationalized "decision". The plan-reviewer (Phase 3) FAILs a plan whose architecture contradicts a DC.

## Phase 1: Architecture Analysis

**Light mode (small scope):** If the planning input is inline (no spec doc), scope is ≤5 tasks (excluding test fixtures/data files), no new public contract is introduced, AND the orchestrator has CodeSift on an indexed repo with the feature spanning ≤7 files, the Team Lead MAY perform Phase 1 analysis directly (CodeSift + Read) and SKIP the Architect/Tech-Lead/QA sub-agent fan-out. Rationale: for a tiny/light scope, spinning up 3 sequential sub-agents costs more than the Team Lead analyzing directly with CodeSift + Read on an already-indexed repo (the fan-out agents are now `general-purpose` with CodeSift, so they are no longer crippled — but for ≤7 files the direct pass is still cheaper). Record `Phase 1: direct (small/light scope)` in `## Review Trail`. plan-reviewer (Phase 3) + cross-model validation still run normally. Spec-driven and >5-task / new-contract plans stay on the mandatory full fan-out below.

Dispatch 3 agents SEQUENTIALLY. Each agent receives the output of the previous agent(s) as input context. The 4th step is performed by you (the main agent) as Team Lead synthesis.

The sequential order is mandatory because each agent's analysis depends on what came before: the Architect maps the terrain, the Tech Lead makes decisions based on that map, and the QA Engineer assesses testability of those decisions.

Pass the prior reports in full when practical. If you must compress for token budget, preserve concrete file paths, symbols, risk rankings, and open questions. Do not reduce a prior report to generic prose.

**Dispatch-type note (Claude Code):** these sub-agents dispatch as `general-purpose`, NOT `Explore` — because `Explore` has NO `mcp__codesift__*` access and would re-explore the repo with grep, slower and less accurate (same reason `zuvo:review` uses general-purpose). `general-purpose` HAS CodeSift, so the tables' "Token budget for CodeSift calls" genuinely applies: instruct each agent to run the CodeSift preload and use `search_text` / `search_symbols` / `get_file_tree` / `codebase_retrieval` / `trace_call_chain` for its analysis. Keep them READ-ONLY BY INSTRUCTION — Read + CodeSift only, never `Edit`/`Write`/`git commit` (they produce reports, not code); `general-purpose` *can* write, so the read-only discipline is enforced by the prompt, not the agent type. Where CodeSift is genuinely unavailable, they fall back to Read/Grep/Glob; for doc-only re-reviews, do the analysis inline instead of dispatching.

### Model policy — planning runs on the STRONGEST model

Planning is the most reasoning-critical step in the pipeline: a weak plan cascades into weak execution
across every task. So the Architect / Tech Lead / QA / plan-reviewer sub-agents dispatch on **Opus**
(the strongest tier — each platform resolves the "Opus" label to its top model), NOT Sonnet. Override
with `--model` only when you deliberately accept a cheaper/faster plan.

**Session-model preflight (WARN — never let a weak model quietly author a plan).** Team Lead synthesis
(Step 4) and light-mode direct analysis run on the MAIN SESSION model, which zuvo cannot change (it is
the CLI you launched). If that session model is NOT a top-tier reasoning model — e.g. a `codex-5.4` /
mid-tier / generation-behind model is driving — print, before authoring:

```
[MODEL WARNING] Planning is running on <session-model>, not a top-tier model. A plan sets the ceiling
for the entire build — every execute task inherits its quality. Re-run planning from your STRONGEST
agent (Claude Opus / the newest codex / etc.) for a materially better plan.
```

Proceed only if the user continues, but the warning must be loud. Detect the driver from the ambient
env (`CLAUDE_MODEL`, `CODEX_MODEL`, the codex `config.toml` `model=`, `ANTIGRAVITY_MODEL`); if unknown,
warn generically that planning should be on the strongest available agent.

<!-- PLATFORM:CODEX -->
**🔒 CODEX: SINGLE-AGENT ONLY.** No event wake on this harness (measured: threads = hours of
poll/dead-air). Perform every agent role below YOURSELF, inline and sequentially — read the agent's
instruction file and do that analysis in this context. Thread spawning / `wait_agent` FORBIDDEN.
<!-- /PLATFORM:CODEX -->

### Agent 1: Architect

Read `agents/architect.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Opus (strongest — planning is reasoning-critical; `--model` overrides) |
| Type | general-purpose (read-only: Read + CodeSift only, no Edit/Write) |
| Input | The spec document (spec-driven) or user description + codebase context (inline) |
| Token budget | 5000 for CodeSift calls |

**Expected output:** Architecture Report containing component boundaries, data flow, interfaces, dependency graph, and a Mermaid diagram.

Wait for the Architect report before dispatching the next agent.

### Agent 2: Tech Lead

Read `agents/tech-lead.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Opus (strongest — planning is reasoning-critical; `--model` overrides) |
| Type | general-purpose (read-only: Read + CodeSift only, no Edit/Write) |
| Input | The planning input (spec or user description) AND the Architect's report |
| Token budget | 5000 for CodeSift calls |

**Expected output:** Technical Decisions Report containing pattern selections, library choices, trade-offs, and file structure.

Wait for the Tech Lead report before dispatching the next agent.

### Agent 3: QA Engineer

Read `agents/qa-engineer.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Opus (strongest — planning is reasoning-critical; `--model` overrides) |
| Type | general-purpose (read-only: Read + CodeSift only, no Edit/Write) |
| Input | The planning input (spec or user description), Architect's report, AND Tech Lead's report |
| Token budget | 5000 for CodeSift calls |

**Expected output:** Quality Assessment containing testability review, CQ pre-check, test strategy, and risk areas.

Wait for the QA Engineer report before proceeding to Team Lead synthesis.

### Step 4: Team Lead Synthesis (Main Agent)

You are the Team Lead. You do NOT dispatch a sub-agent for this step. Read `agents/team-lead.md` for the synthesis procedure, then execute it yourself.

Using all three agent reports plus the original spec, decompose the work into ordered TDD tasks. This is the core deliverable of the plan skill.

---

## Phase 2: Plan Document

Write the plan document to `docs/specs/YYYY-MM-DD-<topic>-plan.md` using today's date and a topic slug derived from the spec.

### Plan Document Structure

```markdown
# Implementation Plan: [Feature Name]

**Spec:** [path to spec document | "inline — no spec"]
**spec_id:** [spec_id from the spec's header | "none"]
**planning_mode:** [spec-driven | inline]
**source_of_truth:** [approved spec | inline brief | inline brief (unapproved spec is context only)]
**plan_revision:** 1
**status:** Draft | Reviewed | Approved
**Created:** [date]
**Tasks:** [count]
**Estimated complexity:** [standard/complex mix summary]

## Architecture Summary
[Condensed from Architect report — component list, key interfaces, dependency direction]

## Technical Decisions
[Condensed from Tech Lead report — chosen patterns, libraries, file structure]

## Quality Strategy
[Condensed from QA Engineer report — test approach, risk areas, CQ gates to watch]

## Coverage Matrix
[Deterministic authority -> task mapping]

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 / G1 | [spec AC, deliverable, goal, or constraint] | requirement / deliverable / constraint | Task 2, Task 5 | [context-only note if needed] |

## Review Trail
- Plan reviewer: revision 1 -> APPROVED | ISSUES FOUND ([short summary])
- Cross-model validation: executed -> clean | findings fixed | skipped ([script reason])
- Status gate: Draft | Reviewed | Approved

## Task Breakdown

### Task 1: [Short descriptive name]
**Files:** [list of files to create or modify, with full paths]
**Surface:** backend-logic | api | db | db-data | ui | integration | config | docs
**Complexity:** standard | complex
**Dependencies:** none | Task N, Task M
**Execution routing:** default implementation tier | deep implementation tier

- [ ] RED: [test goal — what behavior to assert, which file, which assertions]
- [ ] GREEN: [implementation targets — symbols to add/change, invariants, interfaces]
  [Optional: scaffold snippet ≤20 LOC if pattern is non-obvious]
- [ ] Verify: `[exact shell command]`
  Expected: [exact expected output or pattern]
- [ ] Acceptance Proof: [for each AC# this task satisfies, copy the proof block from the spec inline]
  - AC#: [id from spec]
    - Surface: [matching surface]
    - Proof: [exact procedure — command, HTTP call, DB query, browser interaction script]
    - Expected: [exit code, response shape, DOM state, screenshot match]
    - Artifact: `zuvo/proofs/task-1-<ac-id>.<ext>`
- [ ] Commit: `[commit message describing behavior added]`

### Task 2: [...]
...
```

## Whole-feature Smoke Proofs

After all tasks complete, `zuvo:execute` runs these end-to-end proofs **before** declaring the feature COMPLETED. Catches structural bugs that span multiple tasks (e.g., round-trip data loss across encode/transform/decode in three tasks).

Copy each smoke proof from the spec's `## Whole-feature Smoke Proofs` section. If the spec marked smoke as "Not applicable" (internal-only subsystem, no user flow), repeat the justification here.

```markdown
## Whole-feature Smoke Proofs

- **SMOKE1 — [name]**
  - Preconditions: [fixtures, env, seeded data]
  - Proof: [full end-to-end script]
  - Expected: [invariants the entire flow must preserve]
  - Artifact: `zuvo/proofs/smoke-<flow-name>.<ext>`
- **SMOKE2 — ...**
```

### Task Authoring Rules

1. **Scope per task = a MILESTONE, not a micro-step. (HARD — 2026-07-17 post-mortem.)** A task is a
   coherent, independently-committable slice of the feature taking roughly **20-60 minutes** of
   implementation — NOT a 2-5-minute micro-step. Micro-steps (individual RED/GREEN pairs, small
   refactors, wiring) are grouped INSIDE the task as an ordered internal checklist; they do NOT get
   their own task, review cycle, proof artifact, or commit. Target **5-10 tasks per plan; >12 is a
   planning smell** that requires explicit justification in the plan header or a scope split (rule 17).
   The 37-task questions-cutover run measured 37h wall / 51 commits / 171 proof artifacts / 12+ full
   suite runs — per-micro-step gating multiplied a fixed overhead into days. Each task still represents one logical unit of work. If it would take longer, split it.
2. **Boundary size:** A task touching more than 5 files, more than one new public surface, or more than two system boundaries is oversized by default. Split it unless you can justify why the files are inseparable. Test fixtures and test-data files (`.json`/`.html`/`.csv` under `tests/fixtures/` or equivalent fixture dirs) do NOT count toward the 5-file boundary. Count only production code plus their direct test files, and state the fixture count separately.
3. **Task intent over exact code:** RED steps include test intent, target assertions, and file path. GREEN steps include symbols to add/change, invariants to maintain, interfaces to implement, and reuse obligations. Include scaffold code only when the pattern is non-obvious, and keep scaffolds at or below 20 LOC. Do NOT write the full implementation.
4. **Exact verification:** The Verify step must include an exact shell command whose exit code proves the claimed invariant. If the expected output mentions a specific value or behavior, the command must assert that value or behavior rather than merely running a script.
5. **Acceptance Proof per task (MANDATORY):** Every task must list its `Acceptance Proof:` block — copying the spec's per-AC proof inline so `zuvo:execute` can run it without re-resolving from spec. Tasks without proofs are rejected by plan-reviewer. See `../../shared/includes/acceptance-proof-protocol.md` for surface taxonomy and proof shapes. **Verify** (rule 4) is an *implementation-detail* check (does my function compile and pass unit tests); **Acceptance Proof** is a *behavior* check (does the AC actually work). Both required — they catch different defects.
6. **Surface field (MANDATORY):** Every task declares one Surface (backend-logic / api / db / db-data / ui / integration / config / docs). Determines proof shape and verification primitive. UI surface enables browser-tool requirement at execute time.
7. **Coverage matrix:** Every Coverage Matrix row must appear in at least one task's Acceptance Proof field. No orphan requirements, deliverables, or constraints. **In addition:** every spec AC must be covered by at least one task's Acceptance Proof — Coverage Matrix and AC list must both be exhaustively mapped.
8. **Whole-feature smoke proofs:** Copy the spec's `## Whole-feature Smoke Proofs` section into the plan verbatim. If the spec marked smoke "Not applicable", repeat the justification. Smoke proofs run after all per-task proofs at execute Phase Final. When smoke proofs apply: (a) the plan MUST include a final numbered task that authors the smoke-test runner file (the `zuvo/proofs/smoke-*` artifact named in the template), with the smoke proofs listed in that task's Acceptance Proof block — otherwise execute Phase Final hits a missing file; (b) every smoke proof MUST map to at least one task's RED sub-suite (a runnable, possibly-mocked end-to-end exercise) so smoke regressions surface during execute rather than only at the end.
9. **Dependencies:** A task can only depend on tasks with a lower number. No circular dependencies. Dependencies must reflect real ordering, not preference. Dependency declaration must trace concrete reads — a task's Dependencies MUST list every prior task whose output (file/symbol/schema column/env var) its RED/GREEN actually reads or imports; transitive coverage is not sufficient; conversely reject declared deps the task does not consume. Common offenders: a feature-flag task that reads a schema column, an orchestrator that reads a schema column, an Acceptance Proof that invokes a higher-numbered symbol. Task numbers are a *partial* order: `zuvo:execute` runs in dependency order, so numbers need not encode priority — only that dependencies point backward. Place the riskiest cross-boundary unit as early as its dependencies allow so adversarial review does not flag deferred risk.
10. **Complexity rating:** `standard` means 1-3 files, existing patterns, one system boundary, and no new public contract. `complex` means 4+ files, 2+ system boundaries, new patterns/contracts, cross-cutting concerns, or high-risk hotspot files. The complexity rating determines which implementation tier the execute phase will use: default for standard, deep for complex.
11. **File limits:** Use `../../rules/file-limits.md` as the planning default. In particular: utilities/helpers <=100 lines, controllers/services <=300 unless the rule explicitly allows more, components <=200/300, hooks <=250. If the plan would exceed these limits, split the task.
12. **Test files:** Every task that creates production code must include a test file. If a task is docs-only or config-only, say so explicitly in the RED step instead of implying a missing test.
13. **Serialize same-file siblings:** Two tasks that both edit the same shared file (a barrel/`index.ts`, a route registry, a DI container, a migrations index) MUST NOT be parallel — make one depend on the other so `zuvo:execute` never dispatches them concurrently onto the same file (lost-edit / merge-clobber hazard). State the serialization in their Dependencies.
14. **Feasibility spike for novel infra:** When the plan introduces infrastructure with real unknowns (a new queue, a new auth provider, a protocol the codebase has never used), make the FIRST dependent task a small de-risking spike that proves the core mechanism works, before tasks build on it. A spike that fails reshapes the plan cheaply; discovering the dead-end at task 12 does not.
15. **Conditional/decision tasks are always-executed gates:** A task whose body is "decide X, then maybe do Y" must be modeled as an always-run gate task that prints an explicit `[DECISION: <X>] → SKIPPED|COMPLETE` marker, never as a task that silently no-ops. `zuvo:execute` must see it ran and what it decided.
16. **Data Model verification before migration/schema tasks:** Before authoring any task that adds a migration or reads an existing table, grep-verify the spec's `## Data Model` column names / types / nullability against the LIVE schema (the actual migration/model files), not the spec's memory. A schema-drift mismatch caught at plan time is one edit; caught at execute adversarial review it is a CRITICAL + a ~600s round.
17. **Scope split / max-3-PR rule. (HARD — 2026-07-17 post-mortem.)** If the plan exceeds ~10
    milestones, spans more than one deliverable boundary, or is a migration/cutover: SPLIT it into
    sequential PLANS shipped as separate PRs (canonical cutover shape: **compat → runtime cutover →
    legacy removal**, max 3). A single long-lived branch that drifts from main for days ends in
    conflict hell (measured: 37h isolated branch → divergence + merge conflicts). Each split plan
    lands on main independently before the next starts.
18. **Reality pre-check — verify what ALREADY EXISTS before authoring tasks. (HARD — 2026-07-16
    invalid plan.)** Before writing the Task Breakdown, check the CODEBASE for each spec item:
    CodeSift (`search_symbols`/`search_text`/`find_references`) or Read the target modules. Every
    task MUST cite the gap it fills (file/symbol that is missing or wrong TODAY). A task whose
    target behavior already exists is NOT authored — it becomes a one-line `already-implemented`
    note in the plan header. The rs_be antifraud plan authored T1-T18 for code that was already
    implemented; the whole plan was invalid and the execute run burned hours discovering it.
17. **Literal-string adversarial dispositions:** A plan-review/adversarial finding that targets a literal string (a log message, an error-text constant, a fixture value) with no behavioral consequence is almost always a false positive — disposition it as `FP: literal-string, no behavior change` in the Review Trail rather than churning the plan to satisfy it.

---

## Phase 3: Plan Review

### Phase 3.0 — Deterministic DAG lint (run FIRST, after any renumber, before the reviewer)

Before dispatching the reviewer, run the deterministic dependency-DAG linter on the plan file. It catches circular deps, forward references (a task depending on a higher number), and missing-task references mechanically — cheaper than a ~600s adversarial round.

```bash
# >>> zuvo:plan-dag-check
_VD=$(command -v verify-plan-dag 2>/dev/null || ls ~/.zuvo/verify-plan-dag 2>/dev/null | head -1 \
      || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/verify-plan-dag 2>/dev/null | head -1)
if [ -n "$_VD" ] && [ -x "$_VD" ]; then
  "$_VD" "docs/specs/YYYY-MM-DD-<topic>-plan.md" || { echo "[PLAN-DAG FAIL] fix the reported dependency/cycle/forward-ref before review"; }
else
  echo "[PLAN-DAG SKIP] verify-plan-dag not installed — DAG checked by reviewer only (warn-only)"
fi
# <<< zuvo:plan-dag-check
```

Fail-loud on exit 1 (fix the dependency/cycle/forward-ref in the plan, then re-run). Warn-only if the script is missing. Re-run after ANY task renumber. In the same pass (no extra dispatch), scan the plan text once for: unresolved placeholders (`YYYY-MM-DD`/`<topic>`/TBD file paths), tasks over the rule-2 file boundary with no stated justification, and AC#s cited in tasks but absent from the Coverage Matrix — each is a one-edit fix here versus a full reviewer revision.

Dispatch the plan reviewer agent to verify the plan against the spec.

### Agent: Plan Reviewer

Read `agents/plan-reviewer.md` for full instructions.

**Dispatch parameters:**

| Field | Value |
|-------|-------|
| Model | Opus (strongest — planning is reasoning-critical; `--model` overrides) |
| Type | general-purpose (read-only: Read + CodeSift only, no Edit/Write) |
| Input | The planning input (spec or user description) AND the plan document |

**Expected output:** Review verdict — either APPROVED or ISSUES FOUND with specific items.

### Review Loop

1. If APPROVED on the current revision: append the verdict to `## Review Trail`, then proceed to cross-model validation.
2. If ISSUES FOUND: revise the plan to address the issues, increment `plan_revision`, update `## Review Trail`, then re-dispatch the reviewer on the new revision.
3. Maximum 3 review iterations. After 3, present the remaining issues to the user and let them decide whether to accept the plan as-is or provide guidance

### Cross-Model Validation (MANDATORY — do NOT skip)

After the plan-reviewer converges, run cross-model validation on the plan file. This catches task bloat, hidden ordering violations, and AC orphans.

```bash
adversarial-review --mode plan --files "docs/specs/YYYY-MM-DD-<topic>-plan.md" --json \
  > zuvo/context/adversarial-plan.json 2> zuvo/context/adversarial-plan.err
```

Read findings from `zuvo/context/adversarial-plan.json`, never from live stdout (truncated stdout cost 4 recovery calls in one field run). Belt: each pass also appends per-provider SUMMARY lines to `~/.zuvo/adversarial.log` — if the capture file is lost, the last SUMMARY row gives status/providers.

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then apply fix policy:
- **CRITICAL** (missing dependency, task requires nonexistent file) → fix in plan, increment `plan_revision`, re-run plan-reviewer
- **WARNING** that changes task size, ordering, dependencies, verification, or coverage → fix in plan, increment `plan_revision`, re-run plan-reviewer
- **WARNING** that does NOT change execution semantics or coverage → append as note to the affected task and record it in `## Review Trail`
- **INFO** → ignore

**Stop rule:** the 3-iteration cap governs the initial plan-reviewer loop only. An adversarial-driven revision gets exactly ONE re-review of the current revision. Once the current revision holds a reviewer APPROVED verdict and a cross-model pass with zero CRITICAL findings, disposition remaining WARNINGs in `## Review Trail` and STOP — never spin another revision solely for optional reordering, task splitting, or duplicated wording.

**Hard budget (deterministic — this prose cap did NOT compose across the 3-document split and produced a 6-hour run).** `adversarial-review --mode plan` enforces a per-plan round budget in the tool itself: after `ZUVO_PLAN_ROUND_BUDGET` passes (default 8) within a 30-min window, it REFUSES to run — prints `PLAN REVIEW BUDGET EXHAUSTED`, emits `{"status":"budget_exhausted"}`, and exits **7** WITHOUT calling any provider. This is shared across ALL documents of a split plan, so 3 docs × unbounded re-reviews can no longer accumulate. On exit 7 / `status: "budget_exhausted"`:
- **Do NOT retry, do NOT wait out the window, do NOT `ZUVO_PLAN_BUDGET_OFF=1` to keep looping.** The budget firing means the loop has already done more review than a plan warrants.
- **Finalize the CURRENT revision:** disposition every outstanding WARNING in `## Review Trail` (apply the trivially-correct ones inline, record the rest as accepted notes), set the plan status (`Reviewed`, or `Approved` per the interactive/async rules), and hand it to the user with a one-line `[BUDGET: N plan-review passes — residual warnings dispositioned, not re-looped]`.
- `ZUVO_PLAN_BUDGET_OFF=1` exists ONLY for a human who deliberately wants an unbounded session; an agent must never set it to escape the breaker.

**Status handling (D2+D3+D4, 2026-05-17):** parse `--json` output (or the script's text-mode summary banners) for non-`ok` status:
- **`status: "single_provider_only"` (exit 3)** — `--rotate`/`--multi` requested but only 1 provider remains after host exclusion. Re-invoke with `--single` and record in `## Review Trail`: `Cross-model validation: single-provider-only (note: install additional provider for diversity)`. Plan may still advance to Reviewed — single-provider validation is a real signal, just narrower.
- **`status: "timeout"` (exit 124)** — ALL providers timed out. Record `Cross-model validation: skipped (timeout)` and proceed.
- **`status: "partial"` (exit 0)** — `timeout_count > 0` but at least one provider returned. Record in `## Review Trail`: `Cross-model validation: partial (N/M providers; M-N timed out)`. Apply fix policy to the findings that did come back. Surface `timeout_count` to user so reduced coverage is visible.

**Cross-call rotation:** if a second adversarial pass is needed after rev bump, capture `providers_used_list[0]` (array field) from pass-1 JSON and pass it via `--exclude-last <name>` on pass-2 to force a different provider's perspective on the revised plan. (Use the array field — the string `providers_used` cannot be indexed with `[0]`.)

Do not set `status: Reviewed` unless the current plan revision has:
1. a plan-reviewer `APPROVED` verdict,
2. a cross-model validation result or explicit script-generated skip reason, and
3. a populated `## Review Trail` reflecting both checks.

### User Approval

The plan follows a strict state machine:

```
Draft → Reviewed (reviewer converged + cross-model recorded) → Approved (by user only)
```

**Interactive mode:** Present the final plan. The user must explicitly approve. Update status to "Approved" only on user confirmation.

<!-- PLATFORM:CURSOR -->
**Async mode (Codex App, Cursor):** A converged reviewer verdict plus cross-model validation moves the plan to `Reviewed` status (NOT `Approved`). Print: "Plan is in Reviewed status. Review the task breakdown, then change status to Approved before running zuvo:execute."
<!-- /PLATFORM:CURSOR -->

`zuvo:execute` MUST check for "Approved" status. It will not start from "Draft" or "Reviewed".

---

## Active Plan Pointer

After the plan reaches `Approved` status, write the active plan pointer using the WRITE protocol from `session-state.md`:

```bash
mkdir -p zuvo/plans
```

Write `zuvo/plans/active-plan.md` with `status: pending`. If the plan is only `Reviewed`, do not write the pointer yet. This keeps `zuvo:execute` aligned with the same approval gate as the plan header.

**Write `status:` and `plan:` as plain lines, never inside an HTML comment** — a git hook parses this file and fail-opens silently if it cannot (see the format contract in `session-state.md`). Verify with `scripts/zuvo-phase.sh status`.

---

## Output

The final plan document at `docs/specs/YYYY-MM-DD-<topic>-plan.md`.

This artifact is the prerequisite for `zuvo:execute`. When the user is ready to implement, the plan itself must be `Approved`; only then should `zuvo:execute` or the active-plan pointer treat it as the source of truth.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] All 3 Phase 1 agents ran sequentially (Architect → Tech Lead → QA Engineer) — OR Light mode used and `Phase 1: direct (small/light scope)` recorded in Review Trail
[ ] Every spec AC maps to at least one task's Acceptance Proof field
[ ] EVERY task has Surface field + Acceptance Proof block (inline, not just AC# reference)
[ ] Whole-feature Smoke Proofs section present (or "Not applicable" with reason)
[ ] Plan-reviewer ran and converged — APPROVED verdict
[ ] Adversarial validation ran (--mode plan)
[ ] Plan status is Approved (interactive) or Reviewed (async)
[ ] Active plan pointer written to zuvo/plans/active-plan.md
[ ] Retrospective bash appends EXECUTED (retros.log + retros.md) — printing markdown is not enough
[ ] append-runlog wrapper invoked and exited 0
[ ] Logs evidence block printed with real `tail` output
```

**Phase order is non-negotiable.** Retro append → log append → final Run: block. Printing the Run: line + retrospective markdown without executing bash leaves the logs empty.

### Retrospective (REQUIRED, before final Run: block)

Follow the retrospective protocol from `retrospective.md`. Fill the 9 fields, then **execute the bash append commands** for `retros.log` and `retros.md`. Then run the Postamble: Forced Evidence block from `retrospective.md`.

If gate check skips (only valid when literally 1-2 tool calls were made): print `RETRO: skipped (trivial session)` and proceed.

### Append run line via wrapper (REQUIRED)

```bash
RUN_LINE="<ISO-8601-Z>\tplan\t<project>\t-\t-\t<VERDICT>\t<TASKS>\t3-phase\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>"
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for plan on <project>)`. If `RETRO_REQUIRED` exit 2 — execute the retro bash first, never bypass with `ZUVO_SKIP_RETRO_GATE=1`.

### Final Run: block (only after wrapper succeeds)

```
Run: <ISO-8601-Z>	plan	<project>	-	-	<VERDICT>	<TASKS>	3-phase	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
Logs: retros.log=ok retros.md=ok(<count> entries) runs.log=ok
```

If any append failed: `PLAN INCOMPLETE`, not a normal Run: line.

---

## Progress Tracking

Report progress at each phase boundary:

```
STEP: Phase 1.1 — Architect Analysis [START]
... agent work ...
STEP: Phase 1.1 — Architect Analysis [DONE]
STEP: Phase 1.2 — Tech Lead Analysis [START]
... agent work ...
STEP: Phase 1.2 — Tech Lead Analysis [DONE]
STEP: Phase 1.3 — QA Engineer Analysis [START]
... agent work ...
STEP: Phase 1.3 — QA Engineer Analysis [DONE]
STEP: Phase 1.4 — Team Lead Synthesis [START]
... task decomposition ...
STEP: Phase 1.4 — Team Lead Synthesis [DONE]
STEP: Phase 2 — Plan Document [START]
... writing plan ...
STEP: Phase 2 — Plan Document [DONE]
STEP: Phase 3 — Plan Review [START]
... reviewer feedback + iterations ...
STEP: Phase 3 — Plan Review [DONE]
```

If `TaskCreate` is available (Claude Code), use structured task tracking instead of inline text.

---

## Failure Handling

- **Agent crash or timeout:** Retry once. If it fails again, log the error and perform that agent's analysis yourself using the CodeSift tools listed in the agent's instructions.
- **CodeSift unavailable:** Warn the user once ("CodeSift not available. Running in degraded mode."), then use Grep/Read/Glob fallbacks as described in `codesift-setup.md`.
- **Spec is ambiguous:** Do not guess. Ask the user to clarify the specific ambiguity before making planning decisions that depend on it.
- **Reviewer and plan disagree after 3 cycles:** Surface both positions to the user. Present the reviewer's concern and your rationale. Let the user decide.
