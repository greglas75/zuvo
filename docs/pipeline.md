# Pipeline

## Overview

The pipeline is Zuvo's structured workflow for non-trivial features. It enforces a strict sequence: understand the problem, design a solution, get approval, plan implementation tasks, then execute with quality gates at every step.

```
zuvo:brainstorm  -->  spec document   -->  zuvo:plan  -->  plan document  -->  zuvo:execute
```

Each phase produces an artifact that the next phase requires. You cannot skip phases. If you invoke `zuvo:plan` without a spec, it redirects to `zuvo:brainstorm`. If you invoke `zuvo:execute` without a plan, it redirects to `zuvo:plan`.

## When to use pipeline vs direct skills

| Situation | Use |
|-----------|-----|
| Feature touches 5+ files or scope is unclear | Pipeline (`zuvo:brainstorm`) |
| Feature needs design decisions or trade-off analysis | Pipeline (`zuvo:brainstorm`) |
| Feature touches 1-5 files with clear scope | `zuvo:build` directly |
| Bug fix | `zuvo:debug` directly |
| Refactoring existing code | `zuvo:refactor` directly |
| Code review | `zuvo:review` directly |

If you are unsure, the router will ask: "This could be handled as a scoped task with `zuvo:build` or through the full pipeline. Which approach fits?"

## Phase 1: Brainstorm (`zuvo:brainstorm`)

**Goal:** Understand the problem and produce an approved design specification.

**Hard gate:** No implementation code is written during brainstorm. The output is a spec document only.

### Agents (parallel)

| Agent | Role | Model |
|-------|------|-------|
| Code Explorer | Scans the codebase for relevant modules, patterns, similar code, and blast radius | Sonnet |
| Domain Researcher | Researches libraries, APIs, established approaches, and prior art | Sonnet |
| Business Analyst | Identifies edge cases, failure modes (per-component with cost-benefit analysis), and acceptance criteria (ship + success tiers) | Sonnet |

All three agents run in parallel. Their reports feed the design dialogue.

### Design dialogue

After agents report, brainstorm enters a conversation with you. Approval is grouped to prevent fatigue:

**Group 1 — Solution shape:**
1. Overall approach (which of the 2-3 options)
2. Data model / schema changes
3. API surface / interface design
4. Integration points with existing code

**Group 2 — Operational concerns** (critical — not rushed):
5. Edge case handling strategy
6. Failure modes and mitigation decisions
7. Rollback strategy
8. Backward compatibility approach

**Group 3 — Validation:**
9. Validation methodology

### Output artifact

`docs/specs/YYYY-MM-DD-<topic>-spec.md` containing:
- Approved design with decision rationale
- Per-component failure mode tables (minimum 3 scenarios each, with detection/impact/recovery/cost-benefit → explicit mitigate/accept/defer/monitor decision)
- Acceptance criteria split into ship criteria (deterministic, fact-checkable) and success criteria (measurable value/quality)
- Validation methodology (concrete script/command, not "review manually")
- Rollback strategy with kill switch mechanism
- Backward compatibility assessment
- Out of scope split into deferred-to-v2 vs permanently excluded

### Spec reviewer

After writing the spec, a Spec Reviewer agent validates 14 checkpoints (C1-C12 including C7b and C8b):

| Checkpoint | Focus |
|------------|-------|
| C1-C6 | Problem statement, design decisions, solution overview, data model, API surface, integration points |
| C7 | Edge cases (input validation) |
| C7b | Failure modes (system resilience) — completeness check against C6 components, structured scenarios, cost-benefit decisions |
| C8 | Ship acceptance criteria |
| C8b | Success acceptance criteria — traceability to validation methodology, measurable output |
| C9 | Out of scope — deferred vs permanent distinction |
| C10 | Open questions |
| C11 | Rollback strategy |
| C12 | Backward compatibility |

## Phase 2: Plan (`zuvo:plan`)

**Goal:** Decompose the approved spec into ordered TDD tasks with exact code targets and verification commands.

**Hard gate:** Requires a spec document in `docs/specs/*-spec.md`.

### Agents (sequential)

| Agent | Role | Model | Why sequential |
|-------|------|-------|----------------|
| Architect | Maps component boundaries, data flow, interfaces, dependency graph | Sonnet | Establishes the terrain |
| Tech Lead | Selects patterns, libraries, makes implementation decisions based on Architect's map | Sonnet | Needs architecture context |
| QA Engineer | Assesses testability of Tech Lead's decisions, identifies test boundaries | Sonnet | Needs implementation decisions |

After all three agents report, the main agent acts as **Team Lead**, synthesizing their outputs into an ordered task list.

### Task format

Each task follows the TDD protocol:

```
- [ ] RED: Write failing test [description]
- [ ] GREEN: Implement [description]
- [ ] Verify: [command + expected output]
- [ ] Commit: [message]
```

A Plan Reviewer agent validates the task ordering, dependency correctness, and coverage of spec requirements.

### Output artifact

`docs/specs/YYYY-MM-DD-<topic>-plan.md` containing the ordered task list, architecture decisions, and test strategy.

## Phase 3: Execute (`zuvo:execute`)

**Goal:** Implement the plan task by task with automated quality enforcement.

**Hard gate:** Requires a plan document in `docs/specs/*-plan.md`.

### Per-task cycle

For each task in the plan:

1. **Implementer agent** writes a failing test (RED), then the minimal code to pass it (GREEN), then refactors
2. **Spec Reviewer agent** verifies the implementation matches the spec
3. **Quality Reviewer agent** runs CQ1-CQ29 (code quality) and Q1-Q19 (test quality) with evidence

If a quality reviewer finds a critical gate violation, the task is sent back to the implementer for correction before moving to the next task.

### Agents per task

| Agent | Role | Model | Type |
|-------|------|-------|------|
| Implementer | Writes tests and production code following TDD | Sonnet | Code (read-write) |
| Spec Reviewer | Verifies code matches spec requirements | Sonnet | Explore (read-only) |
| Quality Reviewer | Runs CQ1-CQ29 and Q1-Q19 gates with evidence | Sonnet | Explore (read-only) |

### Verification protocol

Every completion claim requires fresh evidence. "Tests pass" means running `npm test` (or equivalent) in this session and reading the output. Prior knowledge and logical deduction are not substitutes. See [quality-gates.md](quality-gates.md) for the full scoring system.

### Backlog persistence

Issues found by quality reviewers that are not fixed during execution are persisted to `memory/backlog.md` using the backlog protocol. Nothing above 25% confidence is silently discarded.

## Artifact convention

All pipeline artifacts live in `docs/specs/`:

| Artifact | Naming pattern | Produced by |
|----------|---------------|-------------|
| Spec | `docs/specs/YYYY-MM-DD-<topic>-spec.md` | `zuvo:brainstorm` |
| Plan | `docs/specs/YYYY-MM-DD-<topic>-plan.md` | `zuvo:plan` |

The topic slug is kebab-cased from the feature name (e.g., `user-notifications`, `payment-retry-logic`).

## Token budget estimates

These are approximate costs per phase for a medium-complexity feature (5-10 files affected):

| Phase | Agents | Estimated tokens |
|-------|--------|-----------------|
| Brainstorm | 3 parallel + design dialogue + spec writing | 30-50K |
| Plan | 3 sequential + team lead synthesis + plan writing | 40-60K |
| Execute (per task) | Implementer + 2 reviewers | 15-25K |
| Execute (full, ~8 tasks) | All task cycles | 120-200K |

Total pipeline for a medium feature: approximately 200-300K tokens. Smaller features (3-4 tasks) run closer to 100-150K.

CodeSift reduces token usage by 15-30% compared to degraded mode (Grep/Read fallback) because it returns more precise results with fewer tokens.
