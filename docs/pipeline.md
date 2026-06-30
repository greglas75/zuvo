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

## Pipeline-entry enforcement (stop agents shipping past the gates)

The pipeline is only useful if production-code work actually goes through it. Prompts
and the router are a soft layer — an agent can ignore them and freelance a multi-file
feature with raw `Edit`/`Write`, never invoking `zuvo:build`/`zuvo:execute`, so no
review ever runs. The enforcement below makes that fail deterministically.

### The layers (honest about what each guarantees)

| Layer | Role | Bypassable? |
|-------|------|-------------|
| **CI gate** (`ci/zuvo-pipeline-entry.yml` + `scripts/zuvo-pipeline-entry-ci.sh`) | **THE GUARANTEE** — fails the PR/push server-side | **No** — an agent cannot `--no-verify` or skip a server-side check (FAIL-CLOSED) |
| **pre-push gate** (`hooks/pre-push-gate.sh`) | **primary local enforcement** — blocks the push | only via `--no-verify` → blocked by the next two rows |
| **commit-gate + Stop-gate nudges** | **early warning** — surface before the push/CI block | yes, by design (best-effort, NOT the guarantee) |
| **block-no-verify + git PATH-shim** | `--no-verify` defense | — |
| **using-zuvo router rule** | soft top layer (sets intent) | yes — the gates enforce |

The **signal** is content-keyed review coverage: `zuvo:review`/`zuvo:build`/`zuvo:execute`
write `memory/reviews/<base7>..<head7>-<slug>.md` (with a machine-readable `range:`/`files:`
header) on success only. The gates ask "is THIS range/file-set reviewed?" — a review of
files X never whitelists unrelated files Y, and a crashed run writes nothing.

### What counts as "substantial"

A change is gate-eligible when, counting **production files only** (the classifier excludes
`tests/`, `*.test.*`, `*.spec.*`, `docs/`, `*.md`, config like `*.json`/`*.yml`/`*.toml`/`*rc`,
`*.lock`, `zuvo/`), it changes **≥3 production files OR ≥150 added+deleted lines**. Override
with `ZUVO_GATE_MIN_FILES` (default 3) and `ZUVO_GATE_MIN_LINES` (default 150).

### Enabling the CI gate (the only unbypassable layer)

1. Copy the template into your repo: `cp ci/zuvo-pipeline-entry.yml .github/workflows/`
   (it ships in the plugin under `ci/` and is installed to the cache + `~/.claude/ci/`).
2. It runs on `pull_request` + `push` with `fetch-depth: 0` (full history for merge-base).
3. It fails any substantial change with no covering `memory/reviews/` artifact.

### Escape valves (logged)

- **Local** (`ZUVO_ALLOW_ADHOC=1`): bypasses the pre-push + commit/Stop gates for one
  invocation — use with a reason; it is the documented local escape.
- **CI** (the `zuvo:adhoc-approved` PR label): the ONLY CI escape, and it is **human-applied**
  — an agent cannot self-apply a GitHub label, so it cannot self-exempt the guarantee.

### Honest limits

- The **commit-gate and Stop-gate are nudges, not blocks** — they are bypassable by design
  (staging tricks, harnesses without a Stop hook). They exist to surface the problem early so
  the agent self-corrects; they are NOT load-bearing.
- The **pre-push gate** is bypassable with `--no-verify` (which is why `block-no-verify` + the
  opt-in PATH-shim exist) and only fires where a git pre-push hook is wired.
- **CI is the only unbypassable layer.** If you only enable one thing, enable CI.
- All local gates **fail OPEN**: malformed input / missing repo / git failure / missing lib →
  exit 0. A benign error never opaque-blocks your work. The CI gate (FAIL-CLOSED) is the
  backstop that catches anything a local fail-open lets slip.
- Human (non-agent) commits and pushes are **exempt** (agent-env detection) — these gates
  constrain agents, not you.
- Codex and Antigravity have **no Stop hook**; their coverage is the commit-gate nudge +
  pre-push + CI. Cursor inherits the Claude cache wiring.

#### Known bypasses of the `--no-verify` defense layer (block-no-verify + git-shim)

Four adversarial rounds (gemini, 2026-06-28) hardened the `--no-verify` defense, which is a
*best-effort* layer by design — **CI is the guarantee**. The string-parser (`block-no-verify`)
now uses quote-aware `xargs` tokenization and scans EVERY git invocation in the command, so the
following classes are **CLOSED**: quoted metacharacters in messages, newline-joined / chained
2nd-git invocations, nested-quote encapsulation, `--no-verify` abbreviations, `-uno`/`-nm`
clustering, `-c core.hooksPath` (key=value / attached / boolean) + `git config core.hooksPath`
+ `GIT_CONFIG_*` env injection + `git config alias.x "...--no-verify..."` creation, jq-absent
JSON, and unmatched-quote tokenize-failure (fail-closed). The lib's coverage bug (`files:*`
permanent whitelist) is closed too — coverage now requires range-containment AND files.

Irreducible residue (a command-STRING parser cannot fully decide shell semantics) —
**documented, not chased**; each defeats only the best-effort layer and is caught by the CI
gate (which re-checks review coverage on the pushed content regardless of how it was committed):

- **git alias USAGE** — `git c` where `c` is a pre-existing alias for `commit --no-verify`.
  (Alias *creation* of a hook-skip IS blocked; resolving an alias at *use* time needs a
  `git config --get alias.*` subprocess — recursion/latency risk.)
- **`include.path` indirection** — `git -c include.path=evil.conf` where the included file sets
  hooksPath. Not blocked, because `include.path` is a legitimate, common config feature and its
  value doesn't reveal hooksPath without reading the file; over-blocking it would break real
  workflows.
- **commit-gate mtime** — the commit-gate is a non-blocking *nudge* anyway; pre-push + CI
  re-evaluate the real content. (Deleted-staged-file mtime is now handled.)

The git **PATH-shim** is more robust than the string parser (it receives the real shell-tokenized
argv, so quoting/metachar bypasses don't apply to it). Backlog `B-noverify-hardening` tracks an
optional deeper pass (alias resolution, index blob-hash tracking). **None of this weakens the
guarantee:** the CI gate fails any unreviewed substantial change in the merged range no matter
how the local hooks were evaded.

## Refactor commit-gate (the Prove-before-commit bind)

`zuvo:refactor` has its own enforcement, distinct from pipeline-entry: it stops an agent
from committing a refactor whose **Prove** step (blind audit + adversarial review) it skipped
or whose findings it parked. Prose said "MANDATORY" in 24 places and was ignored by five field
refactors in one day; the bind is now an external git hook, because a hook fires on every harness
and an agent cannot narrate past it.

### How it works

| Piece | Role |
|-------|------|
| **CONTRACT `prove` fields** (`zuvo/contracts/refactor-*.json` → `prove.{blind_audit,adversarial,findings_disposition}`) | the artifact of record — written at Phase 3.5 step 0, BEFORE the commit |
| **`hooks/refactor-safety-gate.sh`** (pre-commit + pre-push) | reads the CONTRACT on `git commit`; **rejects** a commit whose staged files intersect a refactor scope fence whose `prove` is incomplete |
| **`scripts/install-refactor-gate.sh`** | self-installs the hook into the target repo at refactor Phase 0 (idempotent, fail-open) |
| **in-skill self-check** (Completion Gate) | reads the SAME CONTRACT, so it can never disagree with the hook |

Canonical order: **Prove → record in CONTRACT → Gate → Commit (LAST)**. The commit is the final
action; the hook gates it.

### Safe by construction

- **Fail-OPEN** — a missing/broken gate lib `exit 0`s; it can never brick a user's `git commit`.
- **Human bypass** — a commit with no AI-harness env marker (`ZUVO_AI_RUN`/`CLAUDECODE`/…) is never blocked; a crashed AI run never locks a human out.
- **Stale bypass** — a contract older than `ZUVO_GATE_TTL_SEC` (24h) is ignored.
- **Never clobbers** a foreign hook or a version-controlled hooksPath (Husky's `.husky/`).
- **No active refactor CONTRACT ⇒ no-op** — ordinary commits are untouched.
- Escape (logged): `ZUVO_ALLOW_ADHOC=1`.

Cross-harness because git's global `core.hooksPath` (`~/.claude/hooks`, set by `install.sh`) is a
git-level setting — every harness's commits route through it. Tests: `tests/hooks/test-refactor-safety-gate.sh`
and `tests/hooks/test-refactor-gate-install.sh`.
