# Environment Compatibility

> How Zuvo skills adapt to Claude Code, Codex, and Cursor execution environments.

## Execution Models

| Capability | Claude Code | Codex | Cursor 3+ |
|-----------|-------------|-------|-----------|
| Sub-agent dispatch | `Task` / `Agent` tool — parallel, model-routed | Native agents / TOML agents in `~/.codex/agents/` — parallel, sandboxed | Subagents in `.cursor/agents/` — parallel via worktrees |
| Concurrency | Up to 7 parallel subagents | Capped at `max_threads: 6` | Up to 8 parallel agents (10 workers/user, 50/team enterprise) |
| Model selection | Explicit per task dispatch | Fixed per TOML config or session model | Per-agent frontmatter (`model: inherit\|fast\|<id>`) |
| Progress reporting | Structured task updates | Inline progress or native status updates | Inline print: `STEP: [name] [START\|DONE]` |
| User interaction | Native interactive prompts | Codex CLI: ask inline. Codex App async: safest default. | Interactive in Agent tabs, safest default in background agents |
| Agent instructions | Sub-process via Task/Agent tool reads agent markdown | Agent config points to `agents/*.md` for instructions | Subagents read `.cursor/agents/*.md` with YAML frontmatter |
| Worktree isolation | Via `isolation: "worktree"` on Agent tool | Implicit sandbox per agent | Native `/worktree` command, background agents auto-isolate |
| Background agents | Via `run_in_background` parameter | Native async execution | Background agents in cloud or self-hosted VMs |

**Note:** Some skills use **inline prompt dispatch** — agent instructions are embedded in the SKILL.md itself, not in separate `agents/*.md` files. For these skills, the dispatch pattern simplifies to: Claude Code spawns via Task/Agent tool with the inline prompt; Codex spawns ad-hoc or executes inline if only TOML-registered agents are supported; Cursor spawns subagent or executes inline. The per-environment table above still governs concurrency, model selection, and progress reporting.

### Cursor Legacy (pre-3.0)

Cursor versions prior to 3.0 have no subagent support. If running in Cursor <3.0, fall back to sequential execution (read agent instructions yourself, execute one at a time). Detect Cursor version by checking for subagent dispatch capability — if unavailable, use sequential fallback.

## Path Resolution

All paths are relative to the Zuvo plugin root. The plugin root is determined by:

| Environment | Plugin root | Skills location | Rules location |
|-------------|-------------|-----------------|----------------|
| Claude Code | `CLAUDE_PLUGIN_ROOT` env var | `{root}/skills/` | `{root}/rules/` |
| Codex | `~/.codex/skills/` (installed) | `{root}/skills/` | `{root}/rules/` |
| Cursor | `.cursor/plugins/zuvo/` or marketplace install path | `{root}/skills/` | `{root}/rules/` |

When referencing shared includes from a skill or agent, use `{plugin_root}` tokens:
- From any skill: `{plugin_root}/shared/includes/codesift-setup.md`
- From any agent: `{plugin_root}/shared/includes/agent-preamble.md`

## Agent Dispatch Patterns

### Claude Code (full multi-agent)

**Tier 1 — Task tool (recommended for plugins):**

Dispatch sub-agents with the Task tool. Set model and type per agent:

```
Task(
  description: "Analyze code structure for blast radius",
  model: "sonnet",
  type: "Explore",
  instructions: [agent instructions here]
)
```

- `type: "Explore"` — read-only analysis (agent cannot modify files)
- `type: "Code"` — implementation (agent can create and edit files)
- Multiple agents can run in parallel when their work is independent
- Subagents cannot communicate with each other — isolation by design

**Tier 2 — Agent tool (custom subagents):**

Agents defined in `.claude/agents/*.md` with metadata. Claude Code can auto-select based on task description. Agents get scoped tool access (read-only agents get only Read/Grep/Glob). Same isolation model as Tier 1.

**Tier 3 — Agent Teams (experimental):**

Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Adds peer-to-peer messaging via `SendMessage` and shared task lists. Zuvo does NOT use Tier 3 — skills dispatch depth-1 subagents only.

### Codex (native/TOML agents)

Agents are defined as TOML configs in `~/.codex/agents/`. The TOML specifies name, model, sandbox mode, and a pointer to the instruction file:

```toml
name = "blast-radius-mapper"
model = "gpt-5.4"
sandbox_mode = "read-only"
developer_instructions = """
Read your instructions at ~/.codex/skills/build/agents/blast-radius.md
NEVER modify files — analyze and report only.
"""
```

Skills reference agents by name. Codex resolves and spawns them natively.

Constraints:
- `max_threads: 6` — hard ceiling on concurrent agents
- `max_depth: 1` — subagents cannot spawn sub-subagents (aligned with Zuvo's architecture)
- All agents must be pre-registered in TOML — no dynamic spawning at runtime
- No inter-agent messaging

### Cursor 3+ (parallel subagents)

Cursor 3 supports subagents defined as markdown files:

**Project-level:** `.cursor/agents/*.md`
**User-level:** `~/.cursor/agents/*.md`

```markdown
---
name: blast-radius-mapper
description: Analyzes blast radius of code changes across the codebase
model: inherit
readonly: true
is_background: false
---

[Agent instructions here — same content as Claude Code agent .md files]
```

**Frontmatter fields:**

| Field | Values | Purpose |
|-------|--------|---------|
| `name` | kebab-case string | Agent identifier |
| `description` | One paragraph | Used by Cursor for auto-selection |
| `model` | `inherit`, `fast`, or specific model ID | Model routing |
| `readonly` | `true` / `false` | Read-only agents cannot modify files |
| `is_background` | `true` / `false` | Run in cloud VM with worktree isolation |

**Dispatch:** Skills can reference subagents by name. Cursor spawns them in parallel (up to 8 concurrent, 10 workers per user). Each subagent gets its own context and tool access.

**Worktree isolation:** Background agents (`is_background: true`) automatically run in isolated git worktrees. Foreground subagents share the workspace — coordinate to avoid file conflicts.

### Cursor Legacy / Sequential Fallback

For Cursor versions <3.0 or when subagent dispatch is unavailable:

1. Read the agent's instruction file (e.g., `agents/blast-radius.md`)
2. Perform that analysis yourself in the current context
3. Maintain identical output format and quality standards

All agents execute sequentially. Quality gates and evidence requirements do not change.

## Dispatch Decision Tree

When a skill needs to dispatch N agents:

```
1. Is Task/Agent tool available? (Claude Code)
   → YES: Dispatch all N in parallel via Task tool
   → NO: continue

2. Are TOML agents registered? (Codex)
   → YES: Dispatch by name, up to 6 concurrent
   → NO: continue

3. Is subagent dispatch available? (Cursor 3+)
   → YES: Dispatch up to 8 concurrent subagents
   → NO: continue

4. Fallback (Cursor <3.0, unknown environment)
   → Execute each agent's work sequentially yourself
   → Same output format, same quality standards
```

## Progress Tracking

Use structured progress when available, inline text when not:

```
# If TaskCreate is available (Claude Code):
TaskCreate with full phase list, update status as you go

# If structured task updates are NOT available (Codex, Cursor):
STEP: Phase 1 — Code Exploration [START]
... analysis work ...
STEP: Phase 1 — Code Exploration [DONE]
STEP: Phase 2 — Design Dialogue [START]
```

## User Interaction

When a skill needs user input (confirmation, choice between options):

- **Claude Code:** Use the platform's interactive question/approval mechanism.
- **Codex CLI:** Ask inline in the current conversation when clarification is necessary.
- **Cursor (foreground):** Use interactive prompts in Agent tabs.
- **Codex App async / Cursor background / Automations:** Proceed with the safest default choice and document which default was chosen and why.

Hard rule: Never push to a remote repository without explicit user confirmation, regardless of environment. If the current environment cannot confirm interactively, skip the push step entirely and state that pushing is a separate manual step.

## Codex Execution Modes

| Capability | Codex CLI | Codex App |
|-----------|-----------|-----------|
| User interaction mid-task | Yes (Enter/Tab) | Async (submit message) |
| Approval modes | untrusted/on-request/never | Implicit auto-approve |
| File system | Local with sandbox | Cloud container (12h cache) |
| Home directory | Real `~` | Ephemeral `~` |
| Network | Configurable | Restricted |

## Cursor Execution Modes

| Capability | Cursor Foreground | Cursor Background | Cursor Automations |
|-----------|-------------------|-------------------|-------------------|
| User interaction | Interactive in Agent tabs | Async — review on completion | None — fully autonomous |
| Isolation | Shared workspace | Git worktree or cloud VM | Cloud sandbox |
| Subagent support | Yes (up to 4 parallel) | Yes (in isolated environment) | Yes |
| File access | Full project | Worktree copy | Sandbox copy |
| Trigger | User prompt | User prompt (async) | Events (Slack, GitHub, timers, webhooks) |

## Interaction Defaults (non-interactive environments only)

These defaults activate when the skill cannot ask the user a question
(Codex App async mode, Cursor background agents, Cursor Automations).
They do NOT apply to Codex CLI, Claude Code, or Cursor foreground,
where the user is present.

| Gate | Default | Annotation |
|------|---------|------------|
| Plan/spec approval | Proceed | `[AUTO-APPROVED on Codex]` |
| Commit | Commit, NEVER push | -- |
| Dependency unavailable | Log + skip task + continue | Summary at end |
| Clarifying question | Best-judgment | `[AUTO-DECISION]` |
| FINISH mode choices | Skip; instruct user to run manually | -- |

## Model Mapping (cross-environment)

When a skill specifies a model intent, map to the platform's equivalent:

| Intent | Claude Code | Codex | Cursor |
|--------|-------------|-------|--------|
| Fast/cheap (triage, simple analysis) | `haiku` | `gpt-5.4-mini` | `fast` |
| General purpose (most agents) | `sonnet` | `gpt-5.4` | `inherit` |
| Deep reasoning (architecture, spec review) | `opus` | `gpt-5.4` + high reasoning | specific frontier model |
| Implementation (code writing) | `sonnet` or `opus` | `gpt-5.3-codex` | `inherit` |
