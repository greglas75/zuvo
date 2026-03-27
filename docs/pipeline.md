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
| Business Analyst | Identifies edge cases, acceptance criteria, and problem landscape | Sonnet |

All three agents run in parallel. Their reports feed the design dialogue.

### Design dialogue

After agents report, brainstorm enters a conversation with you:

1. **Context summary** -- what exists in the codebase, what exists externally, problem landscape
2. **Clarifying questions** -- asked one at a time, referencing specific agent findings
3. **Approach proposals** -- 2-3 options with trade-offs, one recommended
4. **Section-by-section approval** -- overall approach, data model, API surface, integration points, edge cases

### Output artifact

`docs/specs/YYYY-MM-DD-<topic>-spec.md` containing the approved design, acceptance criteria, files affected, and risk assessment.

### Spec reviewer

After writing the spec, a Spec Reviewer agent validates internal consistency, completeness, and alignment with the approved design decisions.

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
3. **Quality Reviewer agent** runs CQ1-CQ22 (code quality) and Q1-Q17 (test quality) with evidence

If a quality reviewer finds a critical gate violation, the task is sent back to the implementer for correction before moving to the next task.

### Agents per task

| Agent | Role | Model | Type |
|-------|------|-------|------|
| Implementer | Writes tests and production code following TDD | Sonnet | Code (read-write) |
| Spec Reviewer | Verifies code matches spec requirements | Sonnet | Explore (read-only) |
| Quality Reviewer | Runs CQ1-CQ22 and Q1-Q17 gates with evidence | Sonnet | Explore (read-only) |

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
