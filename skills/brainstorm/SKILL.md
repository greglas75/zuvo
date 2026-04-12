---
name: brainstorm
description: >
  Explores a codebase, researches the problem space, and produces an approved design
  specification before any code is written. Use when the user wants to create a new
  feature, add significant functionality, redesign a subsystem, or build something
  that touches multiple parts of the project.
---

# zuvo:brainstorm

Understand the problem thoroughly. Design a solution collaboratively. Write a spec. Get approval. Only then does anything get built.

## Hard Gate

**Do NOT write implementation code.** This skill produces a design specification document. Implementation happens later via `zuvo:plan` and `zuvo:execute`. If the user asks to "just start coding" during brainstorm, explain that the spec must be approved first — skipping design leads to rework.

## Mandatory File Loading

Before starting any work, read these files and confirm they loaded:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and initialization
2. `../../shared/includes/env-compat.md` -- Agent dispatch patterns per environment
3. `../../rules/cq-patterns.md` -- NEVER/ALWAYS code pairs (informs design decisions)
4. `../../shared/includes/run-logger.md` -- Run logging protocol
5. `../../shared/includes/retrospective.md` -- Retrospective protocol

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- READ
  2. env-compat.md       -- READ
  3. cq-patterns.md      -- READ
  4. run-logger.md       -- READ
  5. retrospective.md       -- READ
```

If any required file is missing, STOP. Do not proceed from memory.

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

**Async mode:** If multiple subsystems are detected and you cannot ask the user, pick a single subsystem to scope as an `[AUTO-DECISION]`. Explain why that subsystem is the highest leverage and list the alternatives you deferred.

Tell the user which scope you detected and why.

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

### Agent Dispatch

Refer to `env-compat.md` for the correct dispatch pattern per environment.

**Claude Code:** Use the Task tool to run all three agents in parallel:

```
Agent 1: Code Explorer
  model: "sonnet"
  type: "Explore"
  instructions: [read agents/code-explorer.md]
  input: user request + repo hints + CodeSift availability

Agent 2: Domain Researcher
  model: "sonnet"
  instructions: [read agents/domain-researcher.md]
  input: user request + detected tech stack

Agent 3: Business Analyst
  model: "sonnet"
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

**Ship criteria** (must pass for release — deterministic, fact-checkable):

1. ...
2. ...

**Success criteria** (must pass for value validation — measurable quality/efficiency):

1. ...
2. ...

[Ship criteria can all pass while success criteria fail. That means infrastructure works but value is not delivered. Both tiers are required.]

## Validation Methodology

[How success criteria are measured. Must be concrete: specific script, command, comparison method. Not "compare manually" or "review subjectively." Validation tooling is a prerequisite for implementation, not a deliverable of it.]

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
  model: "sonnet"
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

After the spec-reviewer converges, run cross-model validation on the spec file. This catches hallucinations, contradictions, and scope creep that same-model review misses. Use the shared document-artifact protocol semantics from `adversarial-loop-docs.md` even though this skill implements the call inline.

```bash
adversarial-review --json --mode spec --files "docs/specs/YYYY-MM-DD-<topic>-spec.md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then update the spec's `## Adversarial Review` section and metadata:
- **No provider / empty output:** set `adversarial_review: skipped-no-provider` and write the exact skip reason in `## Adversarial Review`
- **CRITICAL** (hallucinated capability, internal contradiction) → fix in spec, re-run spec-reviewer, then re-run adversarial review
- **WARNING** (missing edge case, vague AC) → append actionable items to `Open Questions` or explicitly resolve them in the spec; set `adversarial_review: warnings`
- **INFO** → summarize briefly in `## Adversarial Review`

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
[ ] Spec-reviewer ran and converged (max 3 iterations)
[ ] Adversarial review ran (--mode spec) — not skipped
[ ] Spec status is Approved (interactive) or Reviewed (async)
[ ] Spec saved to docs/specs/ with spec_id populated
[ ] Run: line printed and appended to log
```

```
Run: <ISO-8601-Z>	brainstorm	<project>	-	-	<VERDICT>	-	3-phase	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

Run logging and retrospective writes are completion gates, not optional cleanup. Append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`, then complete the retrospective appends from `retrospective.md`. If either append fails, report it explicitly instead of silently claiming a clean completion.
