# Environment Compatibility

> How Zuvo skills adapt to different execution environments.

## Execution Models

| Capability | Claude Code | Codex | Antigravity | Cursor |
|-----------|-------------|-------|-------------|--------|
| Sub-agent dispatch | `Agent` tool — parallel, model-routed | TOML agents in `~/.codex/agents/` | Sequential (no spawning) | Sequential (no spawning) |
| Concurrency | Unrestricted background tasks | Limited | Sequential | Sequential |
| User interaction | Native interactive prompts | `[AUTO-DECISION]` | `[AUTO-DECISION]` | `[AUTO-DECISION]` |
| Install root | `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/` | `~/.codex/` | `~/.gemini/antigravity/` | `~/.cursor/` |
| Scripts path | `<install-root>/scripts/` | `~/.codex/scripts/` | `~/.gemini/antigravity/scripts/` | `~/.cursor/scripts/` |
| Adversarial self-exclude | `claude` | `codex-5.3` | `gemini` | `cursor-agent` |

## Secondary Worktree Bootstrap

Refactor/build runs frequently execute inside a **secondary git worktree** (`zuvo:worktree`, or a `refactor/*` branch checked out elsewhere). A worktree shares the repo's git objects but **not** its `node_modules` — and a half-populated, package-local `node_modules` produces type/build/test failures that look like real regressions but are pure environment noise. In the field this was the single largest time-sink for worktree refactors: *"dependency setup and unrelated full-suite failures consumed the most time for the least signal."*

**Before running any verification (tsc / type-check / tests) in a worktree, bootstrap dependencies once:**

1. **Match the toolchain to the main checkout** — same Node major (`node -v` vs the repo's `.nvmrc` / `engines`), same package manager. A version skew alone produces phantom type errors.
2. **Prefer the root install over a fresh per-worktree install.** For a monorepo, reuse the primary checkout's hoisted modules (`ln -s <main-checkout>/node_modules <worktree>/node_modules`) rather than running a full `install` in the worktree.
3. **Reject a partial package-local `node_modules`.** One that exists but is missing workspace deps is worse than none — it makes the resolver fail mid-build. Remove a partial/ignored install and re-link or re-install cleanly before verifying.
4. **Clean ignored partial installs first**, then record the bootstrap state so a later failure is attributable to *code*, not setup.

**Scope verification to the changed surface.** In a secondary worktree, run type-check/tests for the **touched package(s)** (`turbo run type-check --filter=<pkg>`, or the package's own test script) — **not** the whole monorepo. A pre-existing failure in an unrelated package is **out-of-scope** for a behavior-preserving refactor: record it as `pre-existing-out-of-scope`, do not treat it as a blocker, and do not burn the run "rediscovering" errors that were already red before you started. (CodeSift availability is orthogonal — a worktree is a `path=` argument, never a reason to drop to degraded mode.)

## Agent Dispatch

### Claude Code (primary)

Dispatch sub-agents with the Agent tool:

```
Agent(
  description: "Analyze code structure for blast radius",
  model: "sonnet",
  subagent_type: "Explore",
  prompt: [agent instructions here]
)
```

- `subagent_type: "Explore"` — read-only analysis (agent cannot modify files)
- Multiple agents can run in parallel when their work is independent
- **Consecutive dispatch rate-limits = agent failure.** If sub-agent dispatch returns a rate-limit / overloaded / quota error **twice in a row** for the same stage, treat it as a dispatch failure (not a thing to keep retrying): print `[MODE SWITCH] dispatch rate-limited ×2 → single-agent`, record reason `same-model-fallback`/`rate-limited`, and execute that stage's role inline per the single-agent checkpoint protocol. Do NOT silently spin retrying a rate-limited dispatch — it stalls the pipeline; fall back and keep moving.

<!-- PLATFORM:CODEX -->
### Codex

Agents are defined as TOML configs in `~/.codex/agents/`. Skills reference agents by name. Codex resolves and spawns them natively.

```toml
name = "blast-radius-mapper"
model = "gpt-5.4"
sandbox_mode = "read-only"
developer_instructions = """
Read your instructions at ~/.codex/skills/build/agents/blast-radius.md
NEVER modify files — analyze and report only.
"""
```
<!-- /PLATFORM:CODEX -->

<!-- PLATFORM:CURSOR -->
### Cursor

No agent spawning capability. When a skill references an agent:
1. Read the agent's instruction file (e.g., `agents/blast-radius.md`)
2. Perform that analysis yourself in the current context
3. Maintain identical output format and quality standards
<!-- /PLATFORM:CURSOR -->

<!-- PLATFORM:ANTIGRAVITY -->
### Antigravity

Google Antigravity is an agent-first IDE (VS Code fork, released Nov 2025 with Gemini 3). No sub-agent spawning via API — execute sequentially like Cursor.

**Install paths:** `~/.gemini/antigravity/` (skills, shared, rules, scripts)

**Model mapping:** sonnet → gemini-3.1-pro-low, opus → gemini-3.1-pro-high, haiku → gemini-3-flash

**CLI:** `agy` (command-line launcher)

**Env detection:** `VSCODE_GIT_ASKPASS_MAIN` contains `Antigravity` or `ANTIGRAVITY_SESSION_ID` is set

**Adversarial review:** Host auto-excluded (`gemini` provider skipped). Cross-review uses codex, claude, codestral, or cursor-agent. Script at `~/.gemini/antigravity/scripts/adversarial-review.sh`.

When a skill references an agent:
1. Read the agent's instruction file (e.g., `agents/blast-radius.md`)
2. Perform that analysis yourself in the current context
3. Maintain identical output format and quality standards
<!-- /PLATFORM:ANTIGRAVITY -->

## Progress Tracking

Use structured progress when available, inline text when not:

```
# If TaskCreate is available (Claude Code):
TaskCreate with full phase list, update status as you go

# Otherwise:
STEP: Phase 1 — Code Exploration [START]
... work ...
STEP: Phase 1 — Code Exploration [DONE]
```

## User Interaction

| Gate | Interactive (Claude Code) | Non-interactive (Codex App, Cursor) |
|------|---------------------------|--------------------------------------|
| Plan/spec approval | Ask user | Proceed, annotate `[AUTO-APPROVED]` |
| Commit | Ask user | Commit, NEVER push |
| Clarifying question | Ask user | Best-judgment `[AUTO-DECISION]` |

**Hard rule:** Never push to a remote repository without explicit user confirmation, regardless of environment.

## Reviewer Model Routing

Some reviewer workflows need a reviewer that is as strong as possible while still being different from the writer.

Use these abstract reviewer lanes in source artifacts:

- `review-primary` -- strongest preferred reviewer for the current platform
- `review-alt` -- strongest alternate reviewer when `review-primary` would match the writer

Runtime-only fallback lane:

- `same-model-fallback` -- degraded runtime lane used only when a different reviewer cannot be honored

Resolve the concrete reviewer model at runtime with `scripts/reviewer-model-route.sh`.
Do not duplicate the mapping inline in skills or build scripts.

Routing contract:

- detect the writer model from environment
- classify the writer as `small`, `strong_primary`, `strong_alt`, or `unknown`
- emit `review-primary` or `review-alt` when the platform can honor a different reviewer
- emit `same-model-fallback` with an explicit degraded status when the environment cannot honor a different reviewer model
- if the writer classification is `unknown`, emit `routing_status=unknown-writer-model` and do not claim a valid cross-model route
- routing metadata is an orchestration signal, not a security boundary; callers that do not trust their runtime environment must degrade to `unknown-writer-model`

Machine contract for `scripts/reviewer-model-route.sh`:

- runtime routing uses environment detection only
- explicit override flags are allowed only for tests and smoke validation, and only when `ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1`
- stdout must emit one `KEY=VALUE` line per field in this exact order:
  - `platform`
  - `writer_model`
  - `writer_lane`
  - `reviewer_lane`
  - `reviewer_model`
  - `routing_status`
- stdout must contain only those six keys; diagnostics go to stderr
- callers must parse the keys, not positional prose
- callers must not use `eval`; parse line-by-line, for example with `while IFS='=' read -r key value`
- `routing_status=ok` is valid only when `reviewer_model != writer_model`
- token values must be single-line and must not contain `=`; malformed tokens are sanitized to `unknown`
- callers must reject malformed output: exactly 6 unique keys, no duplicates, no extras, no empty values

Decision table:

| Platform capability | Writer classification | Reviewer lane | Routing status |
|---------------------|-------------|---------------|----------------|
| can honor alternate reviewer | `small` | `review-primary` | `ok` |
| can honor alternate reviewer | `strong_alt` | `review-primary` | `ok` |
| can honor alternate reviewer | `strong_primary` | `review-alt` | `ok` |
| cannot honor alternate reviewer | any known lane | `same-model-fallback` | `same-model-fallback` |
| platform unknown | any classification | `same-model-fallback` | `unknown-writer-model` |
| writer classification unknown | `unknown` | `same-model-fallback` | `unknown-writer-model` |

Allowed routing statuses:

- `ok` -- reviewer differs from writer and the platform can honor the route
- `same-model-fallback` -- environment is known but cannot honor a different reviewer
- `unknown-writer-model` -- writer model or platform is unknown, so routing cannot safely pick an alternate
- `routing-failed` -- resolver execution failed, timed out, or emitted malformed output

This routing contract may be reused by isolated blind-audit reviewers and by same-environment adversarial fallback reviewers. If the resolved route is not `ok`, the caller must not pretend the review came from a different model.

Failure mode contract:

- if `scripts/reviewer-model-route.sh` is missing, exits non-zero, or times out, the caller must block or degrade explicitly
- caller-side timeout should fail closed within 5 seconds
- the safe default is to emit all six keys with explicit sentinels:
  - `platform=unknown`
  - `writer_model=unknown`
  - `writer_lane=unknown`
  - `reviewer_lane=same-model-fallback`
  - `reviewer_model=unknown`
  - `routing_status=routing-failed`
- callers must never silently invent their own reviewer mapping after resolver failure
