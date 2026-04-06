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

**Note:** Some skills use **inline prompt dispatch** — agent instructions are embedded in the SKILL.md itself, not in separate `agents/*.md` files. For these skills, the dispatch pattern simplifies to: Claude Code spawns via Task/Agent tool with the inline prompt; Codex spawns ad-hoc or executes inline if only TOML-registered agents are supported; Cursor always executes inline. The per-environment table above still governs concurrency, model selection, and progress reporting.

## Path Resolution

All paths use `{plugin_root}` as a placeholder. You MUST resolve it before reading any file.

### How to resolve `{plugin_root}`

**Step 1:** Try the environment variable:
```bash
echo "$CLAUDE_PLUGIN_ROOT"
```

**Step 2:** If empty, find it from the skill file path. The skill you are executing lives at:
```
{plugin_root}/skills/<skill-name>/SKILL.md
```
So `{plugin_root}` = two directories up from the SKILL.md file.

**Step 3:** If you still can't determine it, search the filesystem:
```bash
ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/shared/includes/env-compat.md 2>/dev/null | head -1
```
The parent of `shared/` in that path is `{plugin_root}`.

**Step 4 (fallback):** Look in PATH for a zuvo entry:
```bash
echo "$PATH" | tr ':' '\n' | grep zuvo | head -1
```
Strip `/bin` from the end to get `{plugin_root}`.

### Resolved paths

Once you have `{plugin_root}`, these paths exist:

| Path | Contents |
|------|----------|
| `{plugin_root}/skills/` | All 39 skill directories |
| `{plugin_root}/rules/` | Code quality rules (cq-patterns.md, testing.md, etc.) |
| `{plugin_root}/shared/includes/` | Shared includes (adversarial-loop.md, env-compat.md, etc.) |
| `{plugin_root}/scripts/` | Shell scripts (adversarial-review.sh, install.sh, etc.) |

### Environment-specific roots

| Environment | Typical resolved path |
|-------------|----------------------|
| Claude Code | `~/.claude/plugins/cache/zuvo-marketplace/zuvo/<version>/` |
| Codex | `~/.codex/` (skills, agents, shared, rules are direct children) |
| Cursor | `~/.cursor/` (skills, agents, shared, rules are direct children) |

### Relative paths from skills

When a SKILL.md references `../../shared/includes/file.md`, that is relative to the skill directory. These are equivalent:
- `../../shared/includes/codesift-setup.md` (relative from `skills/build/SKILL.md`)
- `{plugin_root}/shared/includes/codesift-setup.md` (absolute)

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
