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

1. `{plugin_root}/shared/includes/codesift-setup.md` -- CodeSift discovery and initialization
2. `{plugin_root}/shared/includes/env-compat.md` -- Agent dispatch patterns per environment
3. `{plugin_root}/rules/cq-patterns.md` -- NEVER/ALWAYS code pairs (informs design decisions)

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- READ
  2. env-compat.md       -- READ
  3. cq-patterns.md      -- READ
```

If any required file is missing, STOP. Do not proceed from memory.

## Scope Check

Before dispatching agents, assess the scope of what the user is asking for:

- **Single concern** (one feature, one module, one workflow): proceed normally.
- **Multiple subsystems** (e.g., "rebuild the entire backend"): decompose first. Ask the user to pick one subsystem to brainstorm. Each subsystem gets its own spec. Trying to brainstorm everything at once produces vague specs that cannot drive implementation.

Tell the user which scope you detected and why.

---

## Phase 1: Code Exploration

Dispatch three agents in **parallel** (background). Each agent investigates one dimension of the problem. Their reports feed into Phase 2.

### CodeSift Setup

Follow the instructions in `codesift-setup.md`:

1. Check whether CodeSift tools are available in the current environment
2. `list_repos()` once to get the repo identifier
3. If not indexed: `index_folder(path=<project_root>)`
4. Pass the repo identifier and CodeSift availability status to each agent

### Agent Dispatch

Refer to `env-compat.md` for the correct dispatch pattern per environment.

**Claude Code:** Use the Task tool to run all three agents in parallel:

```
Agent 1: Code Explorer
  model: "sonnet"
  type: "Explore"
  instructions: [read agents/code-explorer.md]
  input: user request + repo identifier + CodeSift availability

Agent 2: Domain Researcher
  model: "sonnet"
  instructions: [read agents/domain-researcher.md]
  input: user request + detected tech stack

Agent 3: Business Analyst
  model: "sonnet"
  type: "Explore"
  instructions: [read agents/business-analyst.md]
  input: user request + repo identifier + CodeSift availability
```

**Codex / Cursor:** Follow the patterns in `env-compat.md`. On Cursor, execute each agent's analysis sequentially yourself, maintaining the same output format.

### Waiting for Results

Collect all three reports before proceeding to Phase 2. If an agent returns BLOCKED or fails:

- **One agent fails:** Proceed with the two successful reports. Note the gap.
- **Two or more fail:** Inform the user. Ask whether to continue with limited context or investigate the failures.

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

Ask questions **one at a time**. Do not dump a list of 10 questions. Each question should:

- Reference specific findings from the agents (e.g., "The codebase already has a notification service in `src/services/notification.ts`. Should this feature integrate with it or use a separate channel?")
- Offer multiple-choice answers when possible (A/B/C with brief trade-offs)
- Explain why the answer matters for the design

Continue asking until you have enough information to propose approaches. Typical count: 2-5 questions. Stop sooner if the scope is clear.

### Step 3: Propose Approaches

Present 2-3 design approaches. For each approach:

- **Name:** A short descriptive label (e.g., "Event-driven with queue" or "Direct service call")
- **How it works:** 3-5 sentences describing the approach
- **Files affected:** List of files that would be created or modified
- **Trade-offs:** What you gain and what you give up
- **Risk:** What could go wrong or what assumptions it depends on

Mark one approach as the **recommended** choice and explain why.

### Step 4: Section-by-Section Approval

Do not ask the user to approve the entire design in one shot. Walk through it in sections:

1. Overall approach (which of the 2-3 options)
2. Data model / schema changes (if any)
3. API surface / interface design (if any)
4. Integration points with existing code
5. Edge case handling strategy

Get a thumbs-up on each section before moving to the next. If the user pushes back on a section, revise it before continuing.

---

## Phase 3: Spec Document

### Step 1: Write the Spec

Create the file at: `docs/specs/YYYY-MM-DD-<topic>-spec.md`

Use today's date. Derive `<topic>` from the feature name, kebab-cased (e.g., `user-notifications`, `payment-retry-logic`).

Spec document structure:

```markdown
# <Feature Name> -- Design Specification

> **Date:** YYYY-MM-DD
> **Status:** Draft
> **Author:** zuvo:brainstorm

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

### Edge Cases

[Each edge case identified, with the chosen handling strategy]

## Acceptance Criteria

[Numbered list. Each criterion is testable and specific.]

1. ...
2. ...

## Out of Scope

[What this spec explicitly does NOT cover. Prevents scope creep during implementation.]

## Open Questions

[Anything unresolved that must be answered before implementation begins. Empty if all questions were resolved in Phase 2.]
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

### Step 3: Iteration Loop

- If the reviewer returns **APPROVED**: proceed to user review.
- If the reviewer returns **ISSUES FOUND**: fix the listed issues in the spec, then re-dispatch the reviewer. Maximum 3 iterations.
- After 3 iterations with unresolved issues: present the remaining issues to the user and let them decide whether to accept, revise, or defer.

### Step 4: User Approval

Present the final spec to the user. The user may:

- **Approve** -- spec is locked. Proceed to `zuvo:plan` when ready.
- **Request changes** -- revise the spec, re-run reviewer if changes are significant.
- **Reject** -- start over or abandon.

Update the spec status from "Draft" to "Approved" when the user approves.

---

## Output

The deliverable of `zuvo:brainstorm` is an approved spec document at `docs/specs/YYYY-MM-DD-<topic>-spec.md` with status "Approved".

The next step is `zuvo:plan`, which reads this spec and produces an implementation plan. Remind the user of this when brainstorm completes. Do not auto-invoke `zuvo:plan` -- let the user decide when to proceed.

## Run Log

Log this run to `~/.zuvo/runs.log` per `shared/includes/run-logger.md`:
- SKILL: `brainstorm`
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: PASS if spec approved, ABORTED if rejected
- TASKS: `-`
- DURATION: `3-phase`
- NOTES: spec topic (e.g., `user-notifications`)
