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
| Code Explorer | Scans the codebase for relevant modules, patterns, similar code, and blast radius | Opus |
| Domain Researcher | Researches libraries, APIs, established approaches, and prior art | Opus |
| Business Analyst | Identifies edge cases, failure modes (per-component with cost-benefit analysis), and acceptance criteria (ship + success tiers) | Opus |

Exploration/spec agents dispatch on **Opus** (strongest tier — a spec sets the ceiling for the whole
pipeline; `--model` overrides for a deliberately cheaper run). On **Codex** there is no agent
spawning: every role runs inline, single-agent, sequentially (hard rule in `env-compat.md` — the
harness has no event wake, measured 2026-07). A stall watchdog (`*/3` cron + heartbeat) auto-resumes
a brainstorm turn killed by an API error.

All three agents run in parallel (Claude Code only). Their reports feed the design dialogue.

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
| Architect | Maps component boundaries, data flow, interfaces, dependency graph | Opus | Establishes the terrain |
| Tech Lead | Selects patterns, libraries, makes implementation decisions based on Architect's map | Opus | Needs architecture context |
| QA Engineer | Assesses testability of Tech Lead's decisions, identifies test boundaries | Opus | Needs implementation decisions |

Planning is reasoning-critical, so these dispatch on **Opus** (override with `--model`). Light mode
(inline input, ≤5 tasks, ≤7 files, indexed CodeSift) lets the Team Lead skip the fan-out and analyze
directly. A `[MODEL WARNING]` is printed if a non-top-tier session model is authoring the plan. The
same stall watchdog as brainstorm auto-resumes an API-killed plan turn (168-min dead stall measured
2026-07-16 before this existed).

After all three agents report, the main agent acts as **Team Lead**, synthesizing their outputs into an ordered task list.

### Task format

Each task follows the TDD protocol:

```
- [ ] RED: Write failing test [description]
- [ ] GREEN: Implement [description]
- [ ] Verify: [command + expected output]
- [ ] Commit: [message]
```

**Granularity (v1.6.9, hard rules):** a task is a **MILESTONE** — a coherent, independently
committable slice taking ~20-60 min — NOT a 2-5-min micro-step (micro-steps live inside the task as
an internal checklist without their own review/proof/commit). Target **5-10 tasks per plan; >12 is a
planning smell**. Plans exceeding ~10 milestones, spanning deliverable boundaries, or doing a
migration/cutover are SPLIT into sequential plans shipped as separate PRs (max 3: compat → cutover →
legacy removal). Before authoring tasks the plan runs a **reality pre-check** — every task must cite
the concrete gap it fills in TODAY's codebase; already-implemented targets become header notes, never
tasks (rule 18; an 18-task plan for already-implemented code shipped 2026-07-16 before this rule).

A Plan Reviewer agent validates the task ordering, dependency correctness, and coverage of spec requirements (max 3 review iterations, then cross-model validation whose findings are read from the JSON artifact, not truncated stdout).

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
4. **Cross-model adversarial review** on the staged diff — with a hard **re-run economy** (v1.6.14):
   max 2 FULL + 1 DELTA runs per task; artifact freshness is SEMANTIC (lint/format/test-only edits do
   NOT invalidate it); a finding refuted once with base-code proof becomes KNOWN and is never
   re-triaged
5. **Acceptance proof** — the task's ACs are exercised for real; all proofs append to ONE
   consolidated report per task (`zuvo/proofs/task-<N>-report.md`)
6. Orchestrator commits (stage-listed files only), rewrites `execution-state.md`, moves on

**Verification is TARGETED:** each task runs tests/type-check for the touched package only; the FULL
suite runs exactly twice per plan (baseline + Phase Final smoke). **SCOPE-FREEZE:** the task list is
frozen at approval — mid-run discoveries go to backlog or a follow-up plan, never new task numbers.

If a reviewer finds a critical gate violation introduced by this task's diff, the task is sent back to the implementer (max 3 iterations, then post-cap autonomous disposition — the pipeline does not stall waiting for a human).

### Agents per task

| Agent | Role | Model | Type |
|-------|------|-------|------|
| Implementer | Writes tests and production code following TDD | Sonnet (std) / Opus (complex) | Code (read-write) |
| Spec Reviewer | Verifies code matches spec requirements | Sonnet | Explore (read-only) |
| Quality Reviewer | Runs CQ1-CQ29 and Q1-Q19 gates with evidence | Sonnet | Explore (read-only) |

**Platform note:** the multi-agent table applies to Claude Code only (event-driven Task wake). On
**Codex/Cursor/Antigravity** every role executes inline as a sequential checkpoint pass — same
gates, no threads (`[MODE] single-agent (codex hard rule)`); thread dispatch on Codex measured 2026-07
at ~88h of wait_agent polling and 19.5h orchestrator dead-air across a 3-day window.

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

> Wall-clock note (post-v1.6.14): with milestone granularity + the adversarial re-run economy, a
> task should close in ~15-25 min and a plan in minutes-to-tens-of-minutes. The 2026-07 forensics
> measured the OLD pipeline at 5h plans / 20-48h executes — the dominant costs were orchestration
> dead-air and unbounded gate re-runs, both now capped, not model compute.

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
| **work gate** (`hooks/refactor-safety-gate.sh` → `refactor_gate_check` + `plan_execute_gate_check`) | blocks a commit/push that hand-rolls an approved plan, or moves a refactor past an unproven CONTRACT | human committers auto-bypass; `ZUVO_ALLOW_ADHOC=1` (logged) |
| **commit-gate + Stop-gate nudges** | **early warning** — surface before the push/CI block | yes, by design (best-effort, NOT the guarantee) |
| **block-no-verify + git PATH-shim** | `--no-verify` defense | — |
| **using-zuvo router rule** | soft top layer (sets intent) | yes — the gates enforce |

A parallel bind covers the **plan → execute** step (`hooks/lib/refactor-gate-lib.sh ::
plan_execute_gate_check`, chained by `hooks/refactor-safety-gate.sh` on pre-commit and
pre-push): when an approved plan is not being executed and the staged files intersect its
declared `**Files:**`, the commit is blocked — the work must go through `zuvo:execute` rather
than be hand-rolled.

`status: in-progress` in `zuvo/plans/active-plan.md` does **not** on its own buy an exemption.
That field is a free, unverified write, so flipping it was a one-line way around the gate.
The exemption must be **corroborated** by evidence of a real run: an `execution-state.md` that
is in-progress, modified within `ZUVO_GATE_GRACE` (default 6h), and naming the **same plan** —
or an `execute-*.marker` whose `repo_root` matches and whose mtime is inside the same window.
Uncorroborated `in-progress` is treated exactly like `pending`. A stale pointer left behind by a
finished run therefore gates later work: set `status: completed` when a run ends.

**Diagnosing it:** `scripts/zuvo-phase.sh status` shows what the gate actually sees in a repo;
`doctor` gives an ARMED / BLIND / IDLE verdict; `doctor --all` sweeps the fleet;
`normalize [--write]` rewrites a pointer into the dialect the gate reads. This exists because a
gate that fail-opens does so **silently** — the parser and the documented template had drifted
apart (`<!-- status: -->` vs a plain `status:` line) and the gate was dead in 8 of 19 real repos
with nothing reporting it. The doctor shares the gate's own parser, so the two cannot disagree.

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

## plan→execute bind + dogfooding the gates

Two enforcement gaps the v1.4.0 self-review exposed, now closed:

### plan→execute bind (Gap 1)

`zuvo:plan` writes `zuvo/plans/active-plan.md` with `status: pending` after a plan is Approved.
The work-gate's `plan_execute_gate_check` (in `hooks/lib/refactor-gate-lib.sh`, run by the same
`refactor-safety-gate.sh` entry as the refactor CONTRACT check) **blocks** a commit/push whose
staged files intersect that plan's declared `**Files:**` while the plan is still `pending` — i.e.
**hand-rolling the implementation instead of running `zuvo:execute`**. `zuvo:execute` flips the
plan to `in-progress` before its own commits, so the execute path passes; only `pending` blocks.
This is the bind that was missing when the v1.4.0 rebuild was hand-rolled past `zuvo:execute`.
Same safety as the refactor gate: fail-open, human-committer bypass, `ZUVO_ALLOW_ADHOC=1` escape,
no-op when there is no pending plan or no file intersection.

### Dogfooding (Gap 2)

The pipeline-entry pre-push gate is opt-in per repo, and `zuvo-plugin` never opted in — so its own
substantial unreviewed push to main was caught by nothing. Fixed with a **tracked `.githooks/`**
dir (`pre-push`, `pre-commit`) that chains the repo's own `hooks/pre-push-gate.sh` (pipeline-entry)
+ `hooks/refactor-safety-gate.sh` (work-gate), activated per-clone by `scripts/setup-dev-hooks.sh`
(`git config core.hooksPath .githooks` — the one step, since `.git/config` cannot be versioned).
After cloning zuvo-plugin, run `./scripts/setup-dev-hooks.sh` once; the repo then gates its own
commits/pushes. The hooks are versioned and reviewable; `core.hooksPath` is the only per-clone bit.

## Global git-dispatch layer (every repo, freestyle included)

The tracked dispatchers `hooks/git-dispatch/{pre-push,pre-commit}` are installed by
`scripts/install.sh` to `~/.claude/hooks/` (global `core.hooksPath`), replacing the old
pass-throughs that ran only a repo-local hook and silently exited otherwise. Each dispatcher:
captures pre-push stdin once (`feed()`, empty input emits nothing; pre-commit deliberately
never reads stdin — no EOF contract on a terminal), runs the repo-local `.git/hooks/<hook>`
first WITHOUT `exec` (its failure propagates; `exec`-shadowing is dead), then ALWAYS chains
the zuvo gates from its own directory: pre-push → `pre-push-gate.sh` (pipeline-entry) +
`refactor-safety-gate.sh pre-push`; pre-commit → `refactor-safety-gate.sh pre-commit`.
Local hooks are resolved via `--git-common-dir` (worktree-correct; NOT `--git-path hooks`,
which honors `core.hooksPath` and would self-resolve); `$0` symlinks are resolved so a
symlink-installed dispatcher still finds its gates; a scoped `ZUVO_DISPATCH_ACTIVE=hook:repo`
latch stops recursion. Fail-open everywhere — and never silently (WARN on unresolved paths).

**Honest limits:** a repo-local `core.hooksPath` (Husky, or a stray local override — e.g.
QuotasMobi had `core.hooksPath=.git/hooks` set locally) bypasses the global layer entirely;
Windows relies on Git-for-Windows bash executing the extensionless `#!/bin/sh` hooks; repos
that opted into local gate hooks double-run them harmlessly (gates are read-only/idempotent).
**Uninstall:** `git config --global --unset core.hooksPath` restores stock git behavior.
Human commits/pushes are exempt inside the gates (G8 / AI-marker bypass); `ZUVO_ALLOW_ADHOC=1`
remains the logged escape.

### Un-pushed range computation — topology-complete (`@unpushed` sentinel, v1.6.4)

The gate answers "which production files does this push introduce, and are they reviewed?" by
computing an un-pushed file set, then checking content-keyed coverage. Computing that set used to
mean picking a diff **base** (`base..HEAD` + `git diff`), and the right base is git-topology-
dependent — a linear branch, a branch off a far-ahead `develop`, a branch that merged `main` in,
and a branch that merged two remote branches each need a different base. Each shape was a separate
patch (deleted-file `--verify`, `--not --remotes` for develop-ahead, newest-remote-ancestor for
single-merge) and multi-merge still over-scoped — whack-a-mole.

`pg_unpushed_range` now emits a base-free **`@unpushed..<tip>` sentinel**; `pg_changed_production`
/`pg_changed_lines` resolve it with:

```
git log --format= --name-only -z -c <tip> --not --remotes
```

- `--not --remotes` excludes everything already on ANY remote (already pushed ⇒ already gated) —
  develop-ahead deltas, merged-in `main`, every merged branch — for **all** topologies, with no
  base to mis-pick. Linear / develop-ahead / single-merge / multi-merge / octopus all collapse to
  one mechanism.
- `-c` keeps merge **conflict resolutions** but not the merged-in content (no under-scope hole); a
  clean merge contributes nothing.

This closed the whole range-scoping class (incl. the multi-merge case, ex-`B-gate-multimerge`) and
deleted the O(N)-over-remote-refs merge-base loop. Remote-less repos (`pg_unpushed_range` exit 1)
keep the `pg_mergebase_range` fallback — `--not --remotes` with no remotes would select the whole
history. The line count is a deliberate **safe over-count** (per-commit churn ≥ net delta → the
secondary threshold only trips sooner; the authoritative signal is the exact FILE count). The
native pre-push path (`rsha..lsha` from git stdin) is an exact range and still uses `git diff`.

> **Trust assumption (by design):** `--not --remotes` treats anything reachable from a remote-tracking
> ref as already-gated. That holds because a push to any remote had to clear the pre-push + CI gates
> (or a logged `ZUVO_ALLOW_ADHOC` escape). If a remote-tracking ref is stale (never fetched) or points
> at history that bypassed the gates by other means, the un-pushed set is computed against that stale
> view — the CI gate (fail-closed, server-side, recomputes on the PR) is the backstop for that case.
> The sentinel is only ever emitted when remotes exist AND there is un-pushed work; `pg_unpushed_range`
> returns exit 1 (→ merge-base fallback) for a remote-less repo, so the whole-history `--not --remotes`
> footgun is never reached through the gate path.

<!-- Evidence Map (updated sections, 2026-07-18)
| Section | Source |
|---------|--------|
| Brainstorm agents (Opus) | skills/brainstorm/SKILL.md: model:"opus" x4 + Model policy note |
| Brainstorm/plan watchdog | skills/{brainstorm,plan}/SKILL.md: Phase 0.2 Arm the stall-recovery watchdog |
| Plan agents (Opus) + light mode + [MODEL WARNING] | skills/plan/SKILL.md: Model policy section + Light mode para |
| Milestone granularity / >12 smell | skills/plan/SKILL.md: Task Authoring Rules rule 1 |
| Max-3-PR split | skills/plan/SKILL.md: rule 17 |
| Reality pre-check | skills/plan/SKILL.md: rule 18 |
| Adversarial re-run economy (2 FULL + 1 DELTA, semantic freshness, KNOWN) | skills/execute/SKILL.md: Step 7b Re-run ECONOMY + Step 8 pt 3 |
| One proof report per task | shared/includes/acceptance-proof-protocol.md: rule 7 |
| Targeted tests / full suite 2x | skills/execute/SKILL.md: Pre-loop guards (TARGETED, full suite runs ONCE at Phase Final) |
| SCOPE-FREEZE | skills/execute/SKILL.md: SCOPE-FREEZE section |
| Codex single-agent + measured polling numbers | shared/includes/env-compat.md: Codex section (SINGLE-AGENT SEQUENTIAL, HARD RULE, measured) |
| Post-cap disposition | skills/execute/SKILL.md: Retry Limits + no-pause-protocol refs |
-->
