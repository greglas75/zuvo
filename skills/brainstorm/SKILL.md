---
name: brainstorm
description: >
  Explores a codebase, researches the problem space, and produces an approved design
  specification before any code is written. Use when the user wants to create a new
  feature, add significant functionality, redesign a subsystem, or build something
  that touches multiple parts of the project.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - suggest_queries          # KEY — orient on unfamiliar repo
    - codebase_retrieval       # KEY — semantic exploration of problem space
    - get_file_tree
    - get_file_outline
    - search_text
    - search_symbols
    - get_symbol
    - find_references
    - architecture_summary
    - detect_communities       # module structure
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
    react: [react_quickstart, analyze_hooks, analyze_renders, audit_compiler_readiness, trace_component_tree]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service, trace_php_event]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:brainstorm

Understand the problem thoroughly. Design a solution collaboratively. Write a spec. Get approval. Only then does anything get built.

## Hard Gate

**Do NOT write implementation code.** This skill produces a design specification document. Implementation happens later via `zuvo:plan` and `zuvo:execute`. If the user asks to "just start coding" during brainstorm, explain that the spec must be approved first — skipping design leads to rework.

## Mandatory File Loading

### Phase 0 — Bootstrap (load before any work)

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and initialization
2. `../../shared/includes/env-compat.md` -- Agent dispatch patterns per environment
3. `../../shared/includes/acceptance-proof-protocol.md` -- Per-AC proof contract for plan/execute
4. `../../shared/includes/provided-artifact-supremacy.md` -- Design-artifact supremacy (the Provided-Design Check runs BEFORE Phase 1, so this is Phase-0 mandatory, not deferred)

### Deferred — Load when needed (NOT at startup)

5. `../../rules/cq-patterns.md` -- Load at Phase 3 (design decisions), NOT at Phase 0
6. `../../shared/includes/run-logger.md` -- Load at completion only
7. `../../shared/includes/retrospective.md` -- Load at completion only

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md              -- READ
  2. env-compat.md                  -- READ
  3. acceptance-proof-protocol.md   -- READ
  4. provided-artifact-supremacy.md -- READ
  5. cq-patterns.md                 -- DEFERRED (Phase 3)
  6. run-logger.md                  -- DEFERRED (completion)
  7. retrospective.md               -- DEFERRED (completion)
```

If a Phase 0 file is missing, STOP. Deferred files are loaded when their phase begins.

### Phase 0.1 — Retro checkpoint marker (run this bash at bootstrap)

Write a run-marker so an abandoned brainstorm is captured at the next zuvo
skill start, and sweep any prior orphans. This is **ungated** — it never
blocks brainstorm and never fails the skill.

```bash
# >>> zuvo:retro-marker  (plan Task 7 — passive checkpoint capture)
_RS=$(command -v retro-stub 2>/dev/null || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/retro-stub 2>/dev/null | head -1)
_ZH="${ZUVO_HOME:-$HOME/.zuvo}"
_RSK="${SKILL:-brainstorm}"
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
ungated (it must never block or fail brainstorm), so if `ZUVO_HOME` is not
writable no marker is written and the skill proceeds normally — passive
capture is simply skipped for that degraded environment. When a marker *is*
written, `append-runlog` clears it on a clean terminal retro; if brainstorm
is abandoned first, the next skill's `--sweep` emits an ABANDONED stub.

### Phase 0.2 — Arm the stall-recovery watchdog

Follow the **ARM** section of `../../shared/includes/stall-recovery.md` with `skill=brainstorm`: seed
`zuvo/context/brainstorm.heartbeat` (`status: running`, `resume: zuvo:brainstorm`) and — **if `CronCreate` is
available** — arm a `*/3 * * * *` cron tagged `[zuvo-watchdog skill=brainstorm project=…]` that runs
`zuvo-watchdog-check` and re-invokes `zuvo:brainstorm` on a RESUME verdict. This closes the measured gap
where a brainstorm turn killed by an API error sat DEAD for 168 minutes until the user re-prompted
(2026-07-16, rs_be) — the watchdog resumes it in ~3 min. Idempotent (skip if this run's tag is in
`CronList`); if `CronCreate` is absent print the `/loop 3m zuvo:brainstorm` fallback line and continue.
Never block on watchdog setup. **Disarm on clean completion** (right after the run-log append):
write `status: done` to the heartbeat and `CronDelete` the id from its `cron_id:` line (belt:
`CronList` → delete any job whose prompt contains `[zuvo-watchdog skill=brainstorm`).

## Interaction Modes

Detect the environment per `env-compat.md`:

**Interactive mode (Claude Code CLI, Codex CLI):**
- Ask clarifying questions one at a time (Phase 2, Step 2)
- Present approaches and get section-by-section approval (Phase 2, Steps 3-4)
- User explicitly approves the spec before status changes to "Approved"

<!-- PLATFORM:CURSOR -->
**Async mode (Codex App, Cursor, any non-interactive environment):**
- Skip clarifying questions -- make best-judgment decisions
- Annotate every decision as `[AUTO-DECISION]` with rationale and alternatives
- Produce the complete spec in one pass
- Set status to `Reviewed` (NOT `Approved`) -- user must explicitly approve after review
- Set `approval_mode: async`, `approved_at: null`
- Do NOT auto-transition to `zuvo:plan`
- Treat Codex App as async even if the user replies in-thread later. A live follow-up message does NOT retroactively convert the run into interactive mode
<!-- /PLATFORM:CURSOR -->
<!-- PLATFORM:ANTIGRAVITY -->
**Async mode (Antigravity, non-interactive):** Same behavior as Cursor async mode above — apply the same [AUTO-DECISION] annotation and `Reviewed` status rules.
<!-- /PLATFORM:ANTIGRAVITY -->


## Scope Check

Before dispatching agents, assess the scope of what the user is asking for:

- **Single concern** (one feature, one module, one workflow): proceed normally.
- **Multiple subsystems** (e.g., "rebuild the entire backend"): decompose first. Ask the user to pick one subsystem to brainstorm. Each subsystem gets its own spec. Trying to brainstorm everything at once produces vague specs that cannot drive implementation.
- **Meta-design target** (new SKILL/agent-team, not a code feature in CWD): treat the analogous existing skill dir (e.g., `skills/<similar>/`) as the "codebase" for the Phase 1 Code Explorer, and SKIP CodeSift repo-indexing expectations — do not assume a CWD repo feature.

**Async mode:** If multiple subsystems are detected and you cannot ask the user, pick a single subsystem to scope as an `[AUTO-DECISION]`. Explain why that subsystem is the highest leverage and list the alternatives you deferred.

Tell the user which scope you detected and why.

---

## Provided-Design Check (BEFORE Phase 1 repo exploration)

Run `provided-artifact-supremacy.md` now. If the user provided a design artifact (a prototype, `HANDOFF.md`, mockup, screenshot, reference URL, "match this / 1:1 / like the prototype"):

1. **It is the SOURCE OF TRUTH for WHAT to build** — not the existing repo. The repo informs HOW.
2. **Read it IN FULL** (not skim) and extract a `## Design Constraints` checklist (DC-1, DC-2…), quoting every explicit do/don't/`single`/`one`/`no`/`must`/`never`.
3. **If the artifact contains code** (`.jsx`/`.tsx`/component files / a runnable demo) → inventory and read those files; the spec's default is to PORT them, not re-derive behavior from prose.
4. Carry `## Design Constraints` into the spec; every design decision that touches a DC cites it. A decision that contradicts a DC is a `[DEVIATION: …]` you surface to the user and wait — NEVER a silent "reference-only" downgrade or a repo-derived rationalization.

This is the gate that stops the dominant expensive failure: building the wrong thing correctly because the agent grounded on its own repo reading instead of the design the user handed it.

---

## Phase 1: Code Exploration

Dispatch three agents in **parallel** (background). Each agent investigates one dimension of the problem. Their reports feed into Phase 2.

### CodeSift Setup

Follow the instructions in `codesift-setup.md`:

1. Check whether CodeSift tools are available in the current environment
2. In single-repo work, let the repo auto-resolve from CWD. Do NOT call `list_repos()` unless you are genuinely operating across multiple repos
3. If unsure whether the repo is indexed: `index_status()`. If not indexed: `index_folder(path=<project_root>)`
4. If CodeSift is available and the task shape is unclear, run `plan_turn(query=<user request>)` once before manual exploration to get tool and file recommendations
5. Pass CodeSift availability status plus any concrete repo hints (key directories, files, or recommended tools) to each agent

<!-- PLATFORM:CODEX -->
**🔒 CODEX: SINGLE-AGENT ONLY.** No event wake on this harness (measured: threads = hours of
poll/dead-air). Perform every agent role below YOURSELF, inline and sequentially — read the agent's
instruction file and do that analysis in this context. Thread spawning / `wait_agent` FORBIDDEN.
<!-- /PLATFORM:CODEX -->

### Agent Dispatch

Refer to `env-compat.md` for the correct dispatch pattern per environment.

**Model policy:** a spec sets the ceiling for the whole plan→execute pipeline, so the exploration and
spec-reviewer agents dispatch on **Opus** (strongest tier; each platform resolves the label to its top
model), not Sonnet — `--model` overrides only when you deliberately accept a cheaper spec. If the MAIN
SESSION model driving synthesis is not top-tier (e.g. a `codex-5.4` / generation-behind model), print
`[MODEL WARNING] Spec is being authored on <session-model>, not a top-tier model — re-run from your
strongest agent for a materially better spec.` before writing the spec.

**Claude Code:** Use the Task tool to run all three agents in parallel:

```
Agent 1: Code Explorer
  model: "opus"
  type: "Explore"
  instructions: [read agents/code-explorer.md]
  input: user request + repo hints + CodeSift availability

Agent 2: Domain Researcher
  model: "opus"
  instructions: [read agents/domain-researcher.md]
  input: user request + detected tech stack

Agent 3: Business Analyst
  model: "opus"
  type: "Explore"
  instructions: [read agents/business-analyst.md]
  input: user request + repo hints + CodeSift availability
```

<!-- PLATFORM:CODEX -->
**Codex:** Follow TOML agent dispatch patterns in `env-compat.md`.
<!-- /PLATFORM:CODEX -->
<!-- PLATFORM:CURSOR -->
**Cursor:** Execute each agent's analysis sequentially yourself, maintaining the same output format.
<!-- /PLATFORM:CURSOR -->

### Waiting for Results

Collect all three reports before proceeding to Phase 2. Agent roles have different criticality:

**Required agents** (failure = degraded spec):
- Code Explorer -- without codebase context, design decisions are blind
- Business Analyst -- without edge cases, the spec will miss critical scenarios

**Optional agent:**
- Domain Researcher -- external context enriches the spec but is not essential

**Failure handling:**
- **Required agent fails:** Retry once. If still fails, proceed but set spec status to "Draft (incomplete -- missing [agent name] analysis)". Note the gap in the spec's Problem Statement. Do NOT auto-approve a spec with missing required analysis.
- **Optional agent fails:** Proceed normally. Note "Domain research unavailable" in the spec.
- **Two or more required agents fail:** STOP. Inform the user. Ask whether to continue with severely limited context or investigate the failures.

### Evidence Calibration

Before Phase 2, verify exact claims from the agent reports before repeating them as fact. This includes:

- Numeric counts ("21 uncovered types", "16 existing specs")
- Existence/absence claims ("seed script missing", "only one importer")
- Runtime location claims ("client-side only", "API-testable", "server-side")
- Reused-schema claims: when the feature reuses an existing schema/table/key, verify against the LIVE schema (grep the table def), not memory — (a) the key's uniqueness/constraints, and (b) the table's NOT NULL columns. A reused table's mandatory columns frequently conflict with a new access pattern (e.g. a GET endpoint cannot supply a NOT NULL `idempotency_key` that a POST middleware always sends). Report constraints explicitly in the Data Model.

Use CodeSift when available; otherwise verify with Read/Grep/Glob. If you cannot verify a claim quickly, keep it out of the factual summary or label it explicitly as `inferred` / `estimate` in the spec.

---

## Phase 2: Design Dialogue

This is a conversation with the user, not a monologue. The goal is to arrive at a design that the user understands and approves.

### Step 1: Present Context

Summarize what the agents found. Organize by dimension:

1. **What exists in the codebase** (from Code Explorer): relevant modules, patterns in use, similar code that already exists, potential blast radius
2. **What exists externally** (from Domain Researcher): libraries, APIs, established approaches, prior art
3. **Problem landscape** (from Business Analyst): edge cases, existing pain points, acceptance criteria candidates

Keep the summary concise. The user does not need the raw agent reports.

### Step 2: Clarifying Questions

**In interactive mode:** Ask questions **one at a time**. Do not dump a list of 10 questions. Each question should:

- Reference specific findings from the agents (e.g., "The codebase already has a notification service in `src/services/notification.ts`. Should this feature integrate with it or use a separate channel?")
- When asking the user to choose, present at least 2 named alternatives with brief trade-offs
- Explain why the answer matters for the design
- Do NOT ask "I recommend X. OK?" If there is only one viable option, record the decision with rationale and move on instead of asking for rubber-stamp approval

Continue asking until you have enough information to propose approaches. Typical count: 2-5 questions. Stop sooner if the scope is clear.

**In async mode:** Make best-judgment decisions for each question you would have asked. Annotate every decision as `[AUTO-DECISION]` with rationale and the alternatives you considered. Proceed directly to proposing approaches.

**Handling mid-dialogue scope changes:** When the user introduces a new requirement or dumps a multi-part answer mid-loop, do not silently absorb it: (1) explicitly acknowledge the added scope, (2) re-state and re-confirm the updated problem statement, and (3) decide with the user whether the new scope belongs in this spec or a follow-up spec before resuming the question loop. In async mode, record the same as an `[AUTO-DECISION]`.

**Codex App clarification:** In Codex App, do NOT ask open-ended clarifying questions unless the decision is high-risk and cannot be safely defaulted. Use `[AUTO-DECISION]` for normal design assumptions, then present the chosen approach for review.

### Step 3: Propose Approaches

Present 2-3 design approaches. For each approach:

- **Name:** A short descriptive label (e.g., "Event-driven with queue" or "Direct service call")
- **How it works:** 3-5 sentences describing the approach
- **Files affected:** List of files that would be created or modified
- **Trade-offs:** What you gain and what you give up
- **Risks:**
  - Dependency failures: what external components could break this approach
  - Data migration risk: what existing state needs transformation
  - Backward compatibility: what breaks for existing users/workflows
  - Estimation confidence: low/medium/high with rationale

Mark one approach as the **recommended** choice and explain why.

### Step 4: Section-by-Section Approval

Do not ask the user to approve the entire design in one shot. Walk through it in groups of related concerns:

**Group 1: Solution shape**
1. Overall approach (which of the 2-3 options)
2. Data model / schema changes (if any)
3. API surface / interface design (if any)
4. Integration points with existing code

**Group 2: Operational concerns** (critical — do not rush even if user shows fatigue)
5. Edge case handling strategy
6. Failure modes and mitigation decisions
7. Rollback strategy
8. Backward compatibility approach

**Group 3: Validation**
9. Validation methodology

Get a thumbs-up on each group before moving to the next. If the user pushes back on a section, revise it before continuing. If user shows fatigue during Group 2, explicitly note: "These are the operational concerns that prevent production fires — worth getting right now rather than discovering gaps during implementation."
A single "go" / "ok" only approves the group currently on the table. It does NOT imply approval of groups that have not yet been presented.

---

## Phase 3: Spec Document

### Step 1: Write the Spec

Create the file at: `docs/specs/YYYY-MM-DD-<topic>-spec.md`

Use today's date. Derive `<topic>` from the feature name, kebab-cased (e.g., `user-notifications`, `payment-retry-logic`).

Spec document structure:

```markdown
# <Feature Name> -- Design Specification

> **spec_id:** YYYY-MM-DD-<topic>-<HHMM>
> **topic:** <human-readable feature name>
> **status:** Draft | Reviewed | Approved
> **created_at:** YYYY-MM-DDTHH:MM:SSZ
> **reviewed_at:** null | YYYY-MM-DDTHH:MM:SSZ
> **approved_at:** null | YYYY-MM-DDTHH:MM:SSZ
> **approval_mode:** interactive | async
> **adversarial_review:** pending | clear | warnings | skipped-no-provider
> **author:** zuvo:brainstorm

`spec_id` is the sole linking key for `zuvo:plan` and `zuvo:execute`. Do not change it after creation. Downstream skills match by `spec_id`, never by filename. The `<HHMM>` suffix prevents collisions when multiple specs are created on the same day.

## Problem Statement

[What problem does this solve? Who is affected? What happens if we do nothing?]

## Design Decisions

[For each decision point discussed in Phase 2, record the chosen approach and why]

## Solution Overview

[High-level description of the chosen approach. Include a diagram if the data flow is non-trivial.]

## Detailed Design

### Data Model

[Schema changes, new types, modified interfaces]

### API Surface

[New endpoints, function signatures, event contracts]

### Integration Points

[How this connects to existing code. Reference specific files and modules.]

### Interaction Contract

[Required for cross-cutting behavioral changes. Define: target surfaces, protected surfaces, override order, validation signal, and rollback boundary. Use this section whenever the feature changes how the agent speaks, classifies, routes, validates, or formats output rather than what product code does. If not applicable, state "Not applicable -- no cross-cutting behavior contract changes."]

### Integration Contract

[REQUIRED for any technical invariant binding 3+ sections (TTL values, lock-function form, dedup/key names, status codes, predicate names). Declare each ONCE with an ID (IC-1, IC-2…); every other section CITES it ("per Integration Contract IC-3") rather than restating in its own words. Example: `IC-1 — Lock function = pg_try_advisory_lock(42::int, cloneId::int)`; all locking references cite IC-1. If no multi-section invariant exists, state "Not applicable." Distinct from Interaction Contract above (behavioral, not technical-invariant DRY).]

### Edge Cases

[Each edge case identified, with the chosen handling strategy]

### Failure Modes

[Per-component failure analysis. Every component mentioned in Solution Overview and Integration Points MUST have a corresponding entry here. Minimum 3 specific scenarios per component — add more rows as needed. "Specific" means concrete situations, not generic categories (e.g., "MCP server timeout after 30s" not "service fails").]

> **Example** (for a CodeSift dependency):
>
> #### CodeSift extraction
>
> | Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
> |----------|-----------|---------------|--------------|----------|------------------|---------------|
> | MCP server timeout (>30s) | timeout exception | all profile-dependent skills | "Profile generation timed out, using fallback" | Auto fall back to inline detection | None — profile not written | 30s |
> | Returns 500 status | HTTP status check | profile generation only | "Profile unavailable, using legacy detection" | Auto fallback + log error | None | Immediate |
> | Valid response but framework=null | profile.stack.framework === null | conventions-dependent skills | Generic checklist instead of framework-specific | User writes profile-overrides.json | Profile written with status=partial | Immediate |
> | Partial results (some extractors succeed, others fail) | per-section status check | skills depending on failed sections | Missing sections noted in profile metadata | Regenerate failed sections on next run | Profile written with gaps flagged | Immediate |
>
> **Cost-benefit:** Frequency: occasional (~2%) × Severity: medium (degraded UX, no data loss) → Mitigation cost: trivial (fallback exists) → **Decision: Mitigate**

#### [Component Name]

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| <scenario 1 — REQUIRED, specific> | <signal> | <affected> | <visible effect> | <mechanism> | <partial state?> | <timing> |
| <scenario 2 — REQUIRED, specific> | ... | ... | ... | ... | ... | ... |
| <scenario 3 — REQUIRED, specific> | ... | ... | ... | ... | ... | ... |
| <scenario 4+ — add more if applicable> | ... | ... | ... | ... | ... | ... |

**Cost-benefit:** Frequency × Severity vs Mitigation Cost → Decision (mitigate / accept / defer / monitor)

[Edge cases cover input validation. Failure modes cover system resilience — what happens when components fail during operation. Both are required.]

## Acceptance Criteria

Every AC has an inline **Proof** sub-bullet — a deterministic procedure (or interaction-with-artifact for UI) that, when run, demonstrates the AC is satisfied. Proofs are the contract between this spec and `zuvo:plan` / `zuvo:execute`. Read `../../shared/includes/acceptance-proof-protocol.md` for the surface taxonomy and proof shape.

**Ship criteria** (must pass for release — deterministic, fact-checkable):

- **AC1 — <single declarative sentence describing the user-observable behavior>**
  - Surface: `backend-logic | api | db | db-data | ui | integration | config | docs`
  - Proof: <command, interaction, or measurement that exhibits the behavior>
  - Expected: <what success looks like — exit code, response shape, DOM state, screenshot match>
  - Artifact: `zuvo/proofs/<task-or-AC-id>.<ext>`
- **AC2 — ...**
  - Surface: ...
  - Proof: ...
  - Expected: ...
  - Artifact: ...

**Success criteria** (must pass for value validation — measurable quality/efficiency):

- **AC-S1 — <single declarative sentence describing the measurable outcome>**
  - Surface: ...
  - Proof: <measurement procedure — script, dashboard query, A/B comparison>
  - Expected: <numeric threshold or comparison target>
  - Artifact: ...
- **AC-S2 — ...**

[Ship criteria can all pass while success criteria fail. That means infrastructure works but value is not delivered. Both tiers are required. AC bullets without a concrete `Proof:` field are rejected by spec-reviewer.]

## Whole-feature Smoke Proofs

[Enumerate the **end-to-end user flows** described in Solution Overview. Each main flow gets its own smoke proof that exercises the entire path — not just one task's slice. Run by `zuvo:execute` at Phase Final, after all per-task proofs pass, before COMPLETED is declared. Catches structural bugs that span tasks (e.g., round-trip data loss across encode → transform → decode).]

- **SMOKE1 — <name of the main flow, e.g., "import HTML, translate, export HTML round-trip">**
  - Preconditions: <fixtures, env vars, seeded data>
  - Proof: <full end-to-end script that drives the flow>
  - Expected: <invariants the entire flow must preserve — e.g., "exported HTML matches imported HTML byte-for-byte except for translated text spans">
  - Artifact: `zuvo/proofs/smoke-<flow-name>.<ext>`
- **SMOKE2 — ...**

If the spec describes only an internal subsystem with no end-user flow (e.g., a refactor), state "Not applicable — no main user flow; per-task proofs cover all behavior." and document why no smoke is needed.

## Validation Methodology

[Aggregator section. Lists the proof runners required by this spec (vitest, curl, playwright, chrome-devtools MCP, etc.) and any infrastructure prerequisites (test DB, fixture files, dev server). Per-AC proof bodies live above; this section is the inventory + setup, not the proof content. Validation tooling is a prerequisite for implementation, not a deliverable of it.]

## Rollback Strategy

[How to disable this feature without rolling back the entire deployment. Must include: kill switch mechanism, fallback behavior, data preservation during rollback.]

## Backward Compatibility

[What existing state (files, schemas, configs, APIs) is affected. Which has precedence during migration. When old format is deprecated. Migration path if applicable.]

## Out of Scope

### Deferred to v2

[Features excluded from this spec but planned for future iterations. Include brief rationale for deferral.]

### Permanently out of scope

[Features that will not be built. Include brief rationale for exclusion.]

## Open Questions

[Anything unresolved that must be answered before implementation begins. Empty if all questions were resolved in Phase 2.]

## Adversarial Review

[Populate after Step 3b. Summarize provider verdicts and any warnings carried into Open Questions. If skipped, write the exact skip reason.]
```

### Step 2: Spec Review

Dispatch the spec reviewer agent:

```
Agent: Spec Reviewer
  model: "opus"
  type: "Explore"
  instructions: [read agents/spec-reviewer.md]
  input: the spec document content + original user request
```

The reviewer checks for completeness, consistency, YAGNI violations, ambiguity, and scope gaps.

If native sub-agent dispatch is unavailable in the current environment, read `agents/spec-reviewer.md` and execute its checklist locally. Print `Spec review performed inline (no sub-agent available)` before reporting the verdict.

### Step 3: Iteration Loop

- If the reviewer returns **APPROVED**: proceed to user review.
- If the reviewer returns **ISSUES FOUND**: fix the listed issues in the spec, then re-dispatch the reviewer. Maximum 3 iterations.
- After 3 iterations with unresolved issues: present the remaining issues to the user and let them decide whether to accept, revise, or defer.

After the internal reviewer converges, update the spec to `status: Reviewed` and set `reviewed_at: <now>`.

### Step 3b: Adversarial Review (MANDATORY — do NOT skip)

**Auth/RBAC contradiction pre-check (before the adversarial run, when the spec touches auth/permissions/tenancy).** Adversarial providers reliably flag these as CRITICAL, so catch them first — cheaper than a re-run. Verify the spec does not contradict itself on access control: a route/action is not declared BOTH public and role-gated; every mutation that touches tenant/org data states its scope filter; the guard layer (middleware vs in-handler vs server-action first-line) is consistent across Integration Points, Failure Modes, and ACs; CSRF/state-changing-GET assumptions match between API Surface and Edge Cases. Fix any contradiction in ONE pass before running the provider round.

After the spec-reviewer converges, run cross-model validation on the spec file. This catches hallucinations, contradictions, and scope creep that same-model review misses. Use the shared document-artifact protocol semantics from `adversarial-loop-docs.md` even though this skill implements the call inline.

```bash
adversarial-review --json --mode spec --files "docs/specs/YYYY-MM-DD-<topic>-spec.md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then update the spec's `## Adversarial Review` section and metadata:
- **No provider / empty output:** set `adversarial_review: skipped-no-provider` and write the exact skip reason in `## Adversarial Review`
- **CRITICAL** (hallucinated capability, internal contradiction) → fix in spec. **Before re-running adversarial, run a self-consistency sweep:** grep the spec for every constant/identifier/predicate/status-code/key-name/lock-form you changed this round and confirm a SINGLE consistent value across Design Decisions, Solution Overview, Detailed Design, Integration Points, Edge Cases, Failure Modes, Rollback Strategy, ACs, and Smoke Proofs. When a CRITICAL targets a cross-cutting property (auth, status, locking, a shared key), update ALL referencing sections in ONE pass. Stale cross-references are the dominant source of round-2+ CRITICALs and are cheaper to fix by grep than by another ~600s provider round. Then re-run spec-reviewer, then re-run adversarial review.
- **WARNING** (missing edge case, vague AC) → append actionable items to `Open Questions` or explicitly resolve them in the spec; set `adversarial_review: warnings`
- **INFO** → summarize briefly in `## Adversarial Review`

**After the adversarial cap (max 2 cross-model runs per `adversarial-loop-docs.md`):** do NOT loop indefinitely or stop to ask. Classify each RESIDUAL CRITICAL: **(a) true blocker** → fix before approval; **(b) accepted trade-off** → document it in the spec's `## Adversarial Review` section with the rationale and converge; **(c) out-of-scope follow-up** → record in `## Open Questions` as owned by `zuvo:plan`/a follow-up spec, and converge. A 2-run cap does NOT short-circuit when a run surfaces a genuinely NOVEL architectural concern (vs. a re-raise of a prior-round fix) — that earns one more targeted pass; a re-labeled nitpick does not.

**Status handling (D2+D3+D4, 2026-05-17):** the script may return non-`ok` JSON status:
- **`status: "single_provider_only"` (exit 3)** — host self-exclusion left only 1 external provider when `--rotate`/`--multi` was requested. Re-invoke with `--single` and note in the spec: `adversarial_review: single-provider-only (install additional provider for diversity)`. Do NOT block spec approval — single-provider review is still a real signal, just narrower.
- **`status: "timeout"` (exit 124)** — ALL providers timed out. Set `adversarial_review: skipped-timeout` and proceed.
- **`status: "partial"` (exit 0)** — some providers returned, others timed out (`timeout_count > 0`). Set `adversarial_review: partial (N/M providers)` and surface the timeout_count in the spec's `## Adversarial Review` section so reviewers know coverage was reduced.

**Cross-call rotation (multi-pass adversarial):** for specs that warrant 2 adversarial passes (CRITICAL findings in pass 1), capture `providers_used_list[0]` from the pass-1 JSON output and thread it via `--exclude-last <name>` into pass 2 — forces a different provider perspective on the revised spec. Use the array field `providers_used_list[0]` (string `providers_used` indexed with `[0]` would error in jq).

The spec MUST NOT transition from `Reviewed` to `Approved` until the `## Adversarial Review` section exists and `adversarial_review` is no longer `pending`.

### Step 4: User Approval

**In interactive mode:** Present the final spec to the user. The user may:

- **Approve** -- spec is locked. Proceed to `zuvo:plan` when ready.
- **Request changes** -- revise the spec, re-run reviewer if changes are significant.
- **Reject** -- start over or abandon.

Before asking for final approval, confirm all of the following:

1. Internal spec review converged and the spec status is `Reviewed`
2. `## Adversarial Review` exists in the spec
3. Group 1, Group 2, and Group 3 approvals have each been collected or explicitly waived by the user

If the user says "go" / "approved" before this checklist is satisfied, treat it as approval of the current section only and continue the process.

Update spec: `status: Approved`, `approved_at: <now>`, `approval_mode: interactive`.

**In async mode:** Set status to `Reviewed`. Set `approved_at: null`. Print: "Spec in Reviewed status. Review all [AUTO-DECISION] annotations, then change status to Approved and set approved_at before running zuvo:plan."

---

## Output

The deliverable of `zuvo:brainstorm` is a spec document at `docs/specs/YYYY-MM-DD-<topic>-spec.md`.

- **Interactive mode:** status is "Approved" after explicit user approval.
- **Async mode:** status is "Reviewed" (not approved). The user must explicitly approve before running `zuvo:plan`.

The next step is `zuvo:plan`, which reads this spec and produces an implementation plan. Remind the user of this when brainstorm completes. Do not auto-invoke `zuvo:plan` -- let the user decide when to proceed.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] All 3 Phase 1 agents ran (Code Explorer, Domain Researcher, Business Analyst)
[ ] Failure modes section present for EVERY component (minimum 3 scenarios each)
[ ] EVERY Acceptance Criterion has Surface, Proof, Expected, Artifact fields filled
[ ] Whole-feature Smoke Proofs section present (or explicit "Not applicable" with reason)
[ ] Spec-reviewer ran and converged (max 3 iterations)
[ ] Adversarial review ran (--mode spec) — not skipped
[ ] Spec status is Approved (interactive) or Reviewed (async)
[ ] Spec saved to docs/specs/ with spec_id populated
[ ] Retrospective bash appends EXECUTED (retros.log + retros.md) — printing markdown is not enough
[ ] append-runlog wrapper invoked and exited 0
[ ] Logs evidence block printed with real `tail` output
```

**Phase order is non-negotiable.** Retro append → log append → final Run: block. Printing the Run: line and the retrospective markdown without executing bash leaves `~/.zuvo/retros.log`, `~/.zuvo/retros.md`, and `~/.zuvo/runs.log` empty — observed failure mode for new projects (e.g. `uptime` 2026-05-09).

### Retrospective (REQUIRED, before final Run: block)

Follow the retrospective protocol from `retrospective.md`. Fill the 9 fields, then **execute the bash append commands** for `retros.log` and `retros.md`. Printing the markdown section is not the retrospective — the bash execution is. Then run the Postamble: Forced Evidence block from `retrospective.md` and paste real `tail` / `stat` output.

If gate check skips (only valid when literally 1-2 tool calls were made): print `RETRO: skipped (trivial session)` and proceed with `ZUVO_SKIP_RETRO_GATE=1` on the next step.

### Append run line via wrapper (REQUIRED)

```bash
RUN_LINE="<ISO-8601-Z>\tbrainstorm\t<project>\t-\t-\t<VERDICT>\t-\t3-phase\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>"
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Capture stdout. Expected: `OK: appended to runs.log (retro verified for brainstorm on <project>)`. If `RETRO_REQUIRED` exit code 2 — go back and execute the retrospective bash, do NOT bypass with `ZUVO_SKIP_RETRO_GATE=1`.

### Final Run: block (only after wrapper succeeds)

```
Run: <ISO-8601-Z>	brainstorm	<project>	-	-	<VERDICT>	-	3-phase	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
Logs: retros.log=ok retros.md=ok(<count> entries) runs.log=ok
```

If any append failed, the block is `BRAINSTORM INCOMPLETE`, not a normal Run: line.
