# Skill Chain Protocol

> Shared include — formalizes artifact passing between skills. Enables multi-skill pipelines from a single command.

## Purpose

Skills produce artifacts (specs, plans, reports, fixes). When one skill's output is another skill's input, this protocol ensures clean handoffs without user re-stating context.

## Artifact Handoff Format

When a skill completes and another skill should follow, emit a `HANDOFF` block:

```
HANDOFF
  source:    zuvo:<source-skill>
  target:    zuvo:<target-skill>
  artifact:  <path-to-artifact>
  type:      <artifact-type>
  metadata:  <key=value pairs>
```

### Artifact Types

| Type | Produced by | Consumed by | Path pattern |
|------|------------|-------------|-------------|
| `spec` | brainstorm | plan | `docs/specs/YYYY-MM-DD-*-spec.md` |
| `plan` | plan | execute | `docs/specs/YYYY-MM-DD-*-plan.md` |
| `review-report` | review | receive-review | inline (conversation context) |
| `audit-report` | *-audit | build, refactor, hotfix | `memory/backlog.md` (entries) |
| `threat-model` | threat-model | security-audit, pentest | `docs/threat-model.md` |
| `incident-report` | incident | hotfix, write-tests | `docs/incidents/YYYY-MM-DD-*.md` |
| `design-system` | design | design-review, build | `.interface-design/system.md` |
| `migration` | migrate | deploy | migration file (framework-specific) |
| `test-report` | write-tests, write-e2e | review | test output (inline) |
| `release` | ship | deploy, release-docs, canary | `memory/last-ship.json` |
| `explanation` | explain | docs | `docs/explanations/*.md` |
| `scaffold` | scaffold | write-tests | generated file paths (inline) |

### Metadata Keys

| Key | When | Example |
|-----|------|---------|
| `verdict` | Always | `PASS`, `WARN`, `FAIL` |
| `cq_score` | After code-producing skills | `19/22` |
| `files_changed` | After code changes | `3` |
| `severity` | After audits | `2C 5H 8M` |
| `version` | After ship | `1.4.0` |
| `risk` | After migrate | `LOW` |

## Predefined Chains

### Chain: build → review → ship

Triggered by: `zuvo:build --chain` or user saying "build, review, and ship"

```
1. zuvo:build [feature]
   → HANDOFF { target: review, artifact: changed files, type: code }
2. zuvo:review (auto-scoped to build's changed files)
   → HANDOFF { target: ship, artifact: review verdict, type: review-report }
3. zuvo:ship (only if review PASS or WARN)
   → DONE
```

If review returns FAIL: chain stops. Print remaining steps and ask user.

### Chain: brainstorm → plan → execute

Existing pipeline. Already enforced by `using-zuvo/SKILL.md`. This protocol formalizes the artifact format.

```
1. zuvo:brainstorm [topic]
   → HANDOFF { target: plan, artifact: docs/specs/*-spec.md, type: spec }
2. zuvo:plan [spec-path]
   → HANDOFF { target: execute, artifact: docs/specs/*-plan.md, type: plan }
3. zuvo:execute [plan-path]
   → DONE (or → review if --chain)
```

### Chain: audit → fix

Triggered by: any audit skill with `--fix` flag or user saying "audit and fix"

```
1. zuvo:<type>-audit [scope]
   → HANDOFF { target: build/hotfix/refactor, artifact: backlog entries, type: audit-report }
2. zuvo:build/hotfix/refactor (auto-scoped to top-priority findings)
   → DONE
```

### Chain: incident → hotfix → deploy

Triggered by: `zuvo:incident --fix` or user saying "investigate and fix"

```
1. zuvo:incident [description]
   → HANDOFF { target: hotfix, artifact: root cause + file:line, type: incident-report }
2. zuvo:hotfix (auto-scoped to incident's root cause)
   → HANDOFF { target: deploy, artifact: hotfix branch, type: code }
3. zuvo:deploy (only if --deploy flag)
   → DONE
```

### Chain: threat-model → security-audit → hotfix

```
1. zuvo:threat-model [scope]
   → HANDOFF { target: security-audit, artifact: CRITICAL threats, type: threat-model }
2. zuvo:security-audit (focused on threat model findings)
   → HANDOFF { target: hotfix, artifact: top vulnerability, type: audit-report }
3. zuvo:hotfix (auto-scoped to highest-risk finding)
   → DONE
```

## Chain Execution Rules

### Starting a Chain

A chain starts when:
1. User explicitly requests it: "build, review, and ship" or "audit and fix"
2. Skill has `--chain` flag
3. Skill's HANDOFF block specifies a target and user confirms

### Continuing a Chain

When receiving a HANDOFF from a previous skill:
1. Read the artifact at the specified path
2. Use metadata to scope the work (e.g., review only changed files)
3. Print: `CHAIN: [source] → [this skill] (artifact: [path])`

### Stopping a Chain

A chain stops when:
- A skill returns `FAIL` verdict (ask user before continuing)
- User interrupts
- The chain reaches its final skill
- A skill's scope guard triggers (e.g., hotfix >3 files)

Print remaining chain steps so the user can resume manually:
```
CHAIN STOPPED at zuvo:review (verdict: FAIL)
  Remaining: zuvo:ship
  Resume: fix review findings, then run zuvo:ship
```

### Chain + Environment

Per `env-compat.md`:
- **Claude Code**: Chains execute sequentially in the same session. HANDOFF is in-context.
- **Codex**: Each skill may be a separate agent. Write HANDOFF to `memory/chain-state.json`.
- **Cursor 3+**: Chains can use foreground subagents sequentially.

### Chain State File (Codex / non-interactive)

When chains span multiple agent invocations, persist state:

```json
{
  "chain_id": "build-review-ship-20260403",
  "started": "2026-04-03T14:30:00",
  "steps": [
    { "skill": "build", "status": "completed", "verdict": "PASS", "artifact": "src/services/export.ts" },
    { "skill": "review", "status": "pending", "artifact": null },
    { "skill": "ship", "status": "pending", "artifact": null }
  ]
}
```

Path: `memory/chain-state.json`. Overwritten per chain. One active chain at a time.

## How Skills Reference This Protocol

Skills that participate in chains should:
1. Read this file during Mandatory File Loading (optional — only if the skill supports chains)
2. Emit HANDOFF block after their output block (before Auto-Docs)
3. Check for incoming chain state at the start (read `memory/chain-state.json` if it exists)

Skills do NOT need to implement chain logic themselves — the router (`using-zuvo`) and this protocol handle orchestration.
