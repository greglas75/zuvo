---
name: architecture
description: >
  Architecture skill with three modes: review existing codebase architecture
  (A1-A9 dimensions), create Architecture Decision Records, or design new
  systems from requirements. Modes: --mode review [path], --mode adr,
  --mode design. Uses CodeSift for module discovery, dependency mapping,
  structural metrics, and temporal coupling detection.
---

# zuvo:architecture — Review, ADR & System Design

Three modes for architecture work: audit an existing codebase structure, document a technical decision, or design a new system from requirements.

**Scope:** Architecture health assessment, technical decision documentation, system design from specifications.
**Out of scope:** Per-file code quality (`zuvo:code-audit`), structural metrics without context (`zuvo:structure-audit`), test quality (`zuvo:test-audit`), individual file refactoring (`zuvo:refactor`).

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
  3. ../../shared/includes/run-logger.md -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Mode 1 (review) CodeSift advantages:**
- `get_knowledge_map(repo, depth=2)` -- module relationships in one call
- `detect_communities(repo, focus="src")` -- architectural boundary discovery
- `find_references(repo, symbol_name)` -- precise fan-in/fan-out per module
- `impact_analysis(repo, since="HEAD~10", depth=2)` -- coupling patterns from recent changes
- `analyze_hotspots(repo, since_days=90)` -- churn hotspots
- `trace_call_chain(repo, symbol_name, direction="callers", depth=3)` -- dependency chains

---

## Phase 0: Parse $ARGUMENTS

**Explicit flags (preferred):**

| Flag | Action |
|------|--------|
| `--mode review [path]` | Architecture Review -- scan codebase, assess structure |
| `--mode adr` | ADR -- create or evaluate an architecture decision record |
| `--mode design` | System Design -- full requirements to design |

**Heuristic fallback (when no `--mode` flag):**

| Input | Detected Mode |
|-------|---------------|
| _(empty)_ | Ask the user if interactive. Otherwise default to `--mode review .` |
| `review [path]` | Review mode |
| "should we use X or Y" | ADR mode |
| "design a system for" | Design mode |
| "document this decision" | ADR mode |

---

## Mode 1: Architecture Review

### When to use

Understanding and evaluating an existing codebase -- before a major refactor, onboarding, tech debt planning, or when something feels structurally wrong.

### Non-goals

| Out of Scope | Use Instead |
|-------------|-------------|
| Security vulnerabilities (except boundaries) | Dedicated security audit |
| Code style and formatting | Linter configuration |
| Test quality | `zuvo:test-audit` |
| Business logic correctness | `zuvo:review` |
| Individual file quality (CQ1-CQ22) | `zuvo:code-audit` |

**Exception:** Architectural security (A8) IS in scope -- auth boundaries, input validation placement, security layer design.

### Step 1 -- Read the Project Structure

Read actual files before any assessment. Never write a review from memory.

1. `package.json` / `pyproject.toml` / `composer.json` -- dependencies, scripts, stack
2. Directory tree (top 2 levels) -- module boundaries
3. Entry points: `main.ts`, `app.module.ts`, `index.ts`, `server.ts`
4. Key domain files: services, controllers, models (sample, not all)
5. `README.md`, `AGENTS.md`, `CLAUDE.md`, any `docs/` folder
6. **Test infrastructure** -- runner config, test locations, coverage config

#### Test discovery (MANDATORY for A6 scoring)

Check ALL locations:
- Co-located: `*.test.ts`, `*.spec.ts`
- Centralized: `__tests__/`, `tests/`, `test/`
- Runner config: `jest.config.*`, `vitest.config.*`, `pytest.ini`, `phpunit.xml`
- CI config: `.github/workflows/`

**Never score A6 without completing test discovery.**

### Step 1.5 -- Architecture Style Detection

Identify which architecture style(s) the codebase uses:

1. Match directory structure against known patterns (layered, feature-based, hexagonal, microkernel, etc.)
2. If monorepo detected, note each app and its individual style
3. Record: **Detected style**, indicators matched, confidence (HIGH/MEDIUM/LOW)

If no clear style matches, record as "Unstructured" with LOW confidence. This is itself an A1 finding.

### Scope Bounding (when `[path]` is specified)

When reviewing a specific path: map architecture within the path only. Cross-boundary imports noted as external deps but not audited. Unobservable dimensions marked as N/A.

### Step 2 -- Map the Architecture

Identify:
- **Layers:** presentation / application / domain / infrastructure -- present and respected?
- **Module boundaries:** main modules/services, cohesion assessment
- **Data flow:** request path from entry point to DB and back
- **External dependencies:** APIs, queues, caches -- coupling assessment
- **Cross-cutting concerns:** auth, logging, error handling -- centralized or scattered?
- **Design patterns:** Repository, Factory, Strategy, Adapter -- correct usage, missing patterns?

### Step 2.5 -- Structural Metrics (MANDATORY)

Gather quantitative metrics before qualitative scoring. They provide evidence and prevent subjective drift.

1. **Dependency cycles:** Check for circular imports between modules/directories. Report cycle count and paths.

2. **Fan-in / fan-out per module:** For each top-level module, count cross-module imports only. Internal subdir imports DO NOT count. High cross-module fan-out (>10) = coupling risk. High fan-in (>8) = fragile shared module.

3. **Module size:** LOC per top-level module. Flag modules >3000 LOC as size candidates for investigation (not automatic god modules -- size alone does not confirm the anti-pattern).

4. **Instability index:** Per module: `I = fan-out / (fan-in + fan-out)`. Stable (I<0.3) modules should be abstract; unstable (I>0.7) should be concrete. Flag violations.

5. **Tool-assisted metrics (JS/TS projects):**
   - `npx madge --circular --extensions ts,tsx [source-dir]` for cycle detection
   - `npx jscpd [source-dir] --min-lines 10 --reporters json` for duplication
   - ESLint complexity rules (if project config available)
   For Python: `radon cc [source-dir] -a -nc`

6. **Temporal coupling (git history):** Identify files that frequently change together despite no direct import relationship.

   ```bash
   git log --format=format: --name-only --since="6 months ago" | \
     awk '/^$/{if(NR>1) for(i in f) for(j in f) if(i<j) print i" "j; delete f; next} {f[$0]}' | \
     sort | uniq -c | sort -rn | head -20
   ```

   High co-change count + NO direct import = temporal coupling (hidden dependency).

Report metrics in a `## Structural Metrics` section before dimension scores.

### Step 3 -- Score Against 9 Dimensions

| # | Dimension | What to check |
|---|-----------|--------------|
| A1 | **Modularity** | Clear boundaries? Low coupling, high cohesion? |
| A2 | **Layering** | Layers respected? No DB in controllers, no logic in repositories? |
| A3 | **Dependency direction** | Dependencies point inward (domain independent of infra)? |
| A4 | **SRP + Anti-patterns** | God classes/modules? Anti-pattern detection? |
| A5 | **Scalability** | Horizontal scaling possible? Shared mutable state? |
| A6 | **Testability** | Tests exist and cover core logic? Pure logic isolated from I/O? |
| A7 | **Observability** | Logging, metrics, tracing? Correlation IDs? |
| A8 | **Security boundary** | Auth/authz at layer boundary? Input validated at entry? |
| A9 | **SOLID compliance** | OCP, LSP, ISP, DIP assessment |

Score each dimension **0-3**:

| Score | Label | Meaning |
|-------|-------|---------|
| 3 | Good | No issues found, pattern correctly applied |
| 2 | Minor gaps | Small deviations, low risk, easy fix |
| 1 | Needs work | Significant issues, structural risk |
| 0 | Critical | Architectural violation actively causing problems |

Each score requires **1-line evidence** with confidence (HIGH/MEDIUM/LOW):
- **HIGH:** direct code evidence (file:line, metric)
- **MEDIUM:** inferred from patterns
- **LOW:** assumption based on limited sample

**Weighted total:** `A_total = sum(A1..A9) / 27 * 100%`

| Total | Verdict |
|-------|---------|
| >= 80% | Healthy |
| 60-79% | Needs attention |
| 40-59% | Significant issues |
| < 40% | Critical |

**Critical gate:** Any A1-A4 = 0 caps the verdict at "Significant issues" at most. A9 is informational, not gated.

### Step 4 -- Identify Top Problems

For each Critical or Needs-work dimension:
- **Pattern:** what is wrong
- **Risk:** what breaks if this stays
- **Fix:** concrete recommendation with file references

### Step 4.5 -- Reconciliation (MANDATORY before report)

Prevent contradictions between report sections:

1. List all preliminary flags from Step 2.5
2. Check each against deeper analysis in Steps 3-4
3. If invalidated: REMOVE from metrics table, anti-pattern summary, and dimension evidence
4. If partially confirmed: downgrade appropriately

**The report must be internally consistent. No "Invalidated Recommendations" section.**

### Output -- Architecture Review Report

```markdown
# Architecture Review: [Project Name]

**Date:** [YYYY-MM-DD]
**Stack:** [framework, language, key dependencies]
**Scope:** [modules/paths reviewed]
**Tools:** [madge, eslint, jscpd, radon, CodeSift -- list used tools]

## Overview
[2-3 sentences: overall structural assessment]

## Architecture Style
**Detected:** [Style] (confidence: HIGH/MEDIUM/LOW)
**Indicators:** [folder patterns matched]

## Architecture Map
[ASCII or described component diagram with data flow]

## Structural Metrics
| Module | LOC | Cross-Module Fan-in | Cross-Module Fan-out | Instability | Notes |
|--------|-----|---------------------|----------------------|-------------|-------|

### Hidden Coupling (Temporal)
| # | Co-changes | File A | File B | Direct Import? | Verdict |

## Dimension Scores
| Dimension | Score (0-3) | Evidence | Confidence |
|-----------|-------------|----------|------------|

**Total: [N]/27 ([N]%) -- [verdict]**
**Critical gate: A1=[N] A2=[N] A3=[N] A4=[N] -- [PASS/FAIL]**

## Critical Issues
[Pattern, Risk, Fix, Files for each]

## Needs-Work Items
[Same format, lower severity]

## Strengths
[What is done well]

## Recommendations
[Prioritized by impact: 1, 2, 3]
```

Save to: `audit-results/architecture-review-YYYY-MM-DD.md`

---

## Mode 2: ADR -- Architecture Decision Record

### When to use
Capturing a significant technical decision: framework choice, data store selection, communication pattern, API design, auth strategy.

### Step 0: Check Existing ADRs

Before writing, search `docs/adr/`, `architecture/decisions/`, `adr/` for:
- Same topic: update existing ADR
- Conflicting decision: new ADR with `Supersedes: ADR-[N]`
- Related decision: add `Related: ADR-[N]` cross-reference

### Step 1: Extract Context

Gather:
- The decision question (concrete: "Use Kafka vs SQS for event bus")
- Constraints (timeline, team expertise, cost, existing stack)
- Forces at play (competing requirements)
- Options (at least 2)

### Step 2: Evaluate Options

Score each option across:

| Dimension | Assessment |
|-----------|-----------|
| Complexity | Implementation, operation, debugging difficulty |
| Cost | Infrastructure, licensing, operational overhead |
| Scalability | 10x growth ceiling, breaking points |
| Team familiarity | Learning curve, existing expertise |
| Maintenance | 2+ year operational burden |
| Lock-in | Migration cost if this is wrong |

### Step 3: Output -- ADR Format

```markdown
# ADR-[N]: [Title -- specific decision question]

**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-[N]
**Date:** [YYYY-MM-DD] | **Deciders:** [names] | **Area:** [Auth/Data/Infra/API/Frontend]

## Context
[2-4 sentences: situation + forces. No solution yet.]

## Decision
[One clear sentence.]

## Options Considered

### Option A: [Name]
| Dimension | Assessment |
|-----------|------------|
[Full evaluation table]

**Pros:** [list] | **Cons:** [list]

### Option B: [Name]
[Same format]

### Option C: Status Quo / Do Nothing
[Cost of change vs benefit]

## Trade-off Analysis
[Synthesize: "A wins on X/Y but loses on Z."]

## Decision Rationale
[Why this option. Connect to constraints.]

## Consequences
- **Easier:** [what this enables]
- **Harder:** [what this constrains]
- **Revisit when:** [trigger conditions]

## Action Items
- [ ] [steps]
```

Save to: `docs/adr/[NNNN]-[slug].md`

---

## Mode 3: System Design

### When to use
Designing a new service, API, or subsystem from requirements.

### Framework (6 Steps)

**Step 1 -- Requirements**
- Functional: what it does (user stories or capabilities)
- Non-functional: scale (RPS), latency (P50/P99), availability (SLA), cost
- Constraints: team size, timeline, tech stack, compliance

**Step 2 -- High-Level Design**
- Component diagram: services, stores, queues, clients
- Data flow: input to output paths
- API contracts: interfaces between components
- Storage choices: data store per data type with rationale

**Step 3 -- Deep Dive** (focus on the hardest parts)
- Data model: entities, relationships, indexes
- API design: endpoints, shapes, pagination
- Caching: what, where, TTL, invalidation
- Queue/event design: topics, consumers, delivery guarantees
- Error handling: retry, dead-letter, circuit breakers

**Step 4 -- Scale and Reliability**
- Load estimation: peak RPS, data volume, storage growth
- Bottlenecks: where it breaks first
- Horizontal scaling: which components
- Failover: per-component failure plan
- Monitoring: health metrics

**Step 5 -- Rollout and Migration (MANDATORY)**
- Migration plan: current state to new design
- Backward compatibility: what breaks, dual-write periods
- Rollout strategy: big bang / gradual / canary with rationale
- Rollback plan: data safety, API compatibility
- Timeline: phases with go/no-go criteria

**Step 6 -- Trade-offs and Open Questions**
- Make every design trade-off explicit
- List assumptions that could change the design
- Identify what to revisit at 10x scale

### Output -- Design Document

```markdown
# [System Name] -- Design Document

**Status:** Draft | Review | Approved | **Date:** [YYYY-MM-DD]
**Author(s):** [Names] | **Related ADRs:** [links]

## Summary
[2-3 sentences]

## Requirements
- **Functional:** [capabilities]
- **Non-functional:** Scale [RPS], Latency [P50/P99], Availability [SLA]
- **Constraints:** [timeline, team, stack, compliance]

## High-Level Design
[ASCII diagram + data flow]

## Data Model
[Key entities, relationships, indexes]

## API Design
[Key endpoints with request/response shapes]

## Rollout and Migration
[Step-by-step or "Greenfield"]

## Trade-offs
| Decision | Chose | Alternative | Why |

## Open Questions and Scale Triggers
```

Save to: `docs/design/[slug].md`

---

## Adversarial Review on Output (MANDATORY — do NOT skip)

After generating the architecture output (review report, ADR, or design document), run cross-model validation.

```bash
adversarial-review --mode audit --files "[output file path]"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** (unsupported claims, missing evidence, contradictions) → fix in output before delivery
- **WARNING** (vague rationale, missing alternatives) → append to open questions section
- **INFO** → ignore

---

## Completion

After completing any mode, print the completion block:

```
ARCHITECTURE COMPLETE
-----
Mode:   [review | adr | design]
Run: <ISO-8601-Z>	architecture	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use the mode label (`review`, `adr`, or `design`).

---

## Backlog Integration (ALL MODES)

After completing any mode, persist actionable items to `memory/backlog.md`:

**Review mode:** Each Critical and Needs-work issue from the report.
**ADR mode:** "Harder" consequences, "Revisit when" triggers, incomplete action items.
**Design mode:** Open questions, scale triggers, rollout risks.

Zero risks may be silently discarded. If the output has consequences, questions, or risks, they must reach the backlog.
