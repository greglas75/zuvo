# Environment Compatibility

> How Zuvo skills adapt to different execution environments.

## Execution Models

| Capability | Claude Code | Other (Codex, Cursor, Antigravity) |
|-----------|-------------|-------------------------------------|
| Sub-agent dispatch | `Agent` tool — parallel, model-routed | Sequential execution (read agent .md, execute yourself) |
| Concurrency | Unrestricted background tasks | Limited or sequential |
| User interaction | Native interactive prompts | Use safest default, annotate `[AUTO-DECISION]` |

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

Same as Cursor — no agent spawning. Execute sequentially. Models mapped to Gemini tiers: sonnet → gemini-3.1-pro-low, opus → gemini-3.1-pro-high.
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
