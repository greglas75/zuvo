# Environment Compatibility

> How Zuvo skills adapt to Claude Code, Codex, and Cursor execution environments.

## Execution Models

| Capability | Claude Code | Codex | Cursor |
|-----------|-------------|-------|--------|
| Sub-agent dispatch | `Task` tool — parallel, model-routed | Native agents / TOML agents in `~/.codex/agents/` — parallel, sandboxed | Not available — single-agent only |
| Concurrency | Unrestricted background tasks | Capped at `max_threads: 6` | Sequential execution only |
| Model selection | Explicit per task dispatch | Fixed per TOML config or session model | Uses whichever model is active — routing ignored |
| Progress reporting | Structured task updates | Inline progress or native status updates | Inline print: `STEP: [name] [START\|DONE]` |
| User interaction | Native interactive prompts | Codex CLI: ask inline. Codex App async: safest default. | Not available — use safest default |
| Agent instructions | Sub-process via Task tool reads agent markdown | Agent config points to `agents/*.md` for instructions | Read `agents/*.md` yourself, execute sequentially |

## Path Resolution

All paths are relative to the Zuvo plugin root. The plugin root is determined by:

| Environment | Plugin root | Skills location | Rules location |
|-------------|-------------|-----------------|----------------|
| Claude Code | `CLAUDE_PLUGIN_ROOT` env var | `{root}/skills/` | `{root}/rules/` |
| Codex | `~/.codex/skills/` (installed) | `{root}/skills/` | `{root}/rules/` |
| Cursor | Project `.cursor/plugins/zuvo/` | `{root}/skills/` | `{root}/rules/` |

When referencing shared includes from a skill, use relative paths from the skill's location:
- From `skills/review/SKILL.md` to shared: `../../shared/includes/codesift-setup.md`
- From `skills/build/agents/blast-radius.md` to shared: `../../../shared/includes/agent-preamble.md`

## Agent Dispatch Patterns

### Claude Code (full multi-agent)

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

### Cursor (sequential fallback)

No agent spawning capability. When a skill references an agent:

1. Read the agent's instruction file (e.g., `agents/blast-radius.md`)
2. Perform that analysis yourself in the current context
3. Maintain identical output format and quality standards

All agents execute sequentially. Quality gates and evidence requirements do not change.

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
- **Codex App async / Cursor:** Proceed with the safest default choice and document which default was chosen and why.

Hard rule: Never push to a remote repository without explicit user confirmation, regardless of environment. If the current environment cannot confirm interactively, skip the push step entirely and state that pushing is a separate manual step.

## Codex Execution Modes

| Capability | Codex CLI | Codex App |
|-----------|-----------|-----------|
| User interaction mid-task | Yes (Enter/Tab) | Async (submit message) |
| Approval modes | untrusted/on-request/never | Implicit auto-approve |
| File system | Local with sandbox | Cloud container (12h cache) |
| Home directory | Real `~` | Ephemeral `~` |
| Network | Configurable | Restricted |

## Interaction Defaults (non-interactive environments only)

These defaults activate when the skill cannot ask the user a question
(Codex App async mode, Cursor, Antigravity). They do NOT apply to
Codex CLI or Claude Code, where the user is present.

| Gate | Default | Annotation |
|------|---------|------------|
| Plan/spec approval | Proceed | `[AUTO-APPROVED on Codex]` |
| Commit | Commit, NEVER push | -- |
| Dependency unavailable | Log + skip task + continue | Summary at end |
| Clarifying question | Best-judgment | `[AUTO-DECISION]` |
| FINISH mode choices | Skip; instruct user to run manually | -- |
