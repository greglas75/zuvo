# Progress Streaming Protocol

> Shared include — standardized progress reporting format for all Zuvo skills. Ensures consistent, parseable output during long operations and multi-agent dispatch.

## Purpose

Skills can take minutes to run (full audits, multi-phase builds, deep threat models). Without progress feedback, the user doesn't know if the skill is working, stuck, or near completion. This protocol standardizes how skills report progress.

## Output Format

### Phase Markers

Every skill phase emits a marker when it starts:

```
[ZUVO:skill-name:phase-N] Phase description
```

Examples:
```
[ZUVO:build:0] Parsing arguments and detecting tier
[ZUVO:build:1] Analyzing scope and risk signals
[ZUVO:build:2] Implementing feature
[ZUVO:build:3] Running tests
[ZUVO:build:4] CQ self-evaluation
```

### Progress Within Phases

For long phases (auditing N files, processing N items), emit progress:

```
[ZUVO:skill-name:phase-N] (M/Total) Current item description
```

Examples:
```
[ZUVO:code-audit:2] (3/12) Auditing src/services/order.service.ts
[ZUVO:code-audit:2] (7/12) Auditing src/controllers/payment.controller.ts
[ZUVO:write-tests:1] (2/5) Writing tests for UserService.create()
[ZUVO:refactor:3] (batch 2/4) Processing auth module
```

### Percentage Progress

For operations where item count is known upfront:

```
[ZUVO:skill-name:phase-N] [=====>    ] 45% — description
```

Use only when total is known. Never show fake percentages.

### Status Transitions

```
[ZUVO:skill-name:START]   Skill invoked with: [arguments summary]
[ZUVO:skill-name:phase-N] Phase description
[ZUVO:skill-name:DONE]    Verdict: PASS | Duration: 4 phases | Files: 3
[ZUVO:skill-name:FAIL]    Reason: [one line]
[ZUVO:skill-name:STOP]    Scope exceeded / user cancelled
```

### Agent Progress (Multi-Agent Dispatch)

When a skill dispatches parallel agents:

```
[ZUVO:skill-name:agents] Dispatching N agents
[ZUVO:skill-name:agent-1] Agent Name — started
[ZUVO:skill-name:agent-1] Agent Name — completed (findings: N)
[ZUVO:skill-name:agent-2] Agent Name — started
[ZUVO:skill-name:agents] All agents completed (N/N)
```

Examples:
```
[ZUVO:brainstorm:agents] Dispatching 3 exploration agents
[ZUVO:brainstorm:agent-1] Architecture Explorer — started
[ZUVO:brainstorm:agent-2] Pattern Analyst — started
[ZUVO:brainstorm:agent-3] Risk Assessor — started
[ZUVO:brainstorm:agent-1] Architecture Explorer — completed (3 approaches identified)
[ZUVO:brainstorm:agent-3] Risk Assessor — completed (2 risks flagged)
[ZUVO:brainstorm:agent-2] Pattern Analyst — completed (4 patterns found)
[ZUVO:brainstorm:agents] All agents completed (3/3)
```

### Chain Progress

When executing a skill chain (see `skill-chain.md`):

```
[ZUVO:chain:build-review-ship] Step 1/3: zuvo:build
[ZUVO:chain:build-review-ship] Step 1/3: zuvo:build — PASS
[ZUVO:chain:build-review-ship] Step 2/3: zuvo:review
[ZUVO:chain:build-review-ship] Step 2/3: zuvo:review — PASS
[ZUVO:chain:build-review-ship] Step 3/3: zuvo:ship
[ZUVO:chain:build-review-ship] Chain completed: 3/3 PASS
```

## Implementation Rules

### When to Emit Progress

| Situation | Action |
|-----------|--------|
| Phase starts | Always emit phase marker |
| Processing N items where N > 3 | Emit progress per item |
| Long operation (>10 seconds expected) | Emit at key milestones |
| Agent dispatched | Emit agent start/complete |
| Chain step transitions | Emit chain progress |
| Phase completes with notable result | Emit summary line |

### When NOT to Emit Progress

- Do not emit progress for trivial operations (<2 seconds)
- Do not emit progress inside agent internals (agents report via their parent)
- Do not emit more than 1 progress line per second (throttle in batch operations)
- Do not emit progress for file reads, config checks, or setup steps

### Verbosity by Environment

Per `env-compat.md`:

| Environment | Progress level |
|-------------|---------------|
| Claude Code (interactive) | Full: phases + item progress + agents |
| Cursor 3+ (interactive) | Full: phases + item progress + agents |
| Codex CLI (local) | Moderate: phases + batch summaries |
| Codex App (cloud) | Minimal: START + phase markers + DONE/FAIL |

### Formatting Rules

1. **Prefix is mandatory**: `[ZUVO:skill:phase]` — always present, always parseable
2. **One line per emission**: no multi-line progress markers
3. **Lowercase skill name**: `[ZUVO:code-audit:2]` not `[ZUVO:Code-Audit:2]`
4. **No emoji in progress**: machine-parseable output, no decorations
5. **Consistent width**: phase numbers are single digits (0-9). If >9 phases, prefix with 0.

### Parsing Regex

Consumers can parse progress with:

```regex
\[ZUVO:([a-z-]+):([a-z0-9-]+)\]\s*(.*)
```

Captures: `skill_name`, `phase_or_status`, `message`

## How Skills Adopt This Protocol

1. Add `progress-streaming.md` to optional reading (not mandatory — skills work without it)
2. At each phase start, print the phase marker
3. In batch operations, print item progress
4. At skill end, print DONE or FAIL status

This is **additive** — skills that don't adopt it still work. Progress output is for user experience, not for skill logic.
