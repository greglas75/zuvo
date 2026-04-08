# Antigravity Build Target -- Design Specification

> **spec_id:** 2026-04-08-antigravity-build-1215
> **topic:** Google Antigravity build target for Zuvo plugin
> **status:** Draft
> **created_at:** 2026-04-08T12:15:00Z
> **approved_at:** null
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

Zuvo currently builds for three platforms: Claude Code (direct copy), Codex (TOML agents + path rewriting), and Cursor (v3 frontmatter + flat agents). Google Antigravity, released February 2026, is a Gemini-powered AI IDE that supports SKILL.md files natively, Claude models alongside Gemini, and MCP configuration. Users who work in Antigravity cannot use Zuvo skills because no build pipeline exists to produce a verified Antigravity distribution.

The user already has broken symlinks at `~/.gemini/antigravity/skills/` pointing to empty `~/.claude/skills/` directories -- a manual workaround that doesn't transform Claude-specific content for Antigravity. A proper build target fixes this.

## Design Decisions

### DD1: Template choice -- Cursor build (not Codex)

**Chosen:** Base the new script on `build-cursor-skills.sh` (567 lines).

**Why:** Antigravity is structurally closer to Cursor than Codex:
- Native markdown agents in subdirectories (no TOML generation needed)
- No flat agent renaming required
- Non-interactive, sequential execution model
- No `readonly:` frontmatter concept

The Codex build (700+ lines) adds complexity for TOML generation, GPT model mapping with different tiers, and Codex-specific auto-decision injection that Antigravity doesn't need.

### DD2: Model mapping -- tiered Gemini models

**Chosen:** Map to Gemini model tiers preserving the quality hierarchy.

| Zuvo model | Antigravity model | Tier |
|---|---|---|
| `model: haiku` | `gemini-3-flash` | fast/cheap |
| `model: sonnet` | `gemini-3.1-pro-low` | balanced |
| `model: opus` | `gemini-3.1-pro-high` | best quality |

**Why:** Antigravity supports both Claude and Gemini models natively. Mapping to Gemini makes skills work without an Anthropic API key (zero friction). The three-tier mapping preserves the cost/quality tradeoff that skills rely on for agent dispatch decisions. Users can manually switch to Claude models in Antigravity's model selector for skills that benefit from Claude-specific capabilities.

### DD3: Agent format -- native subdirectories, no renaming

**Chosen:** Copy agent `.md` files into `skills/<name>/agents/` subdirectories. Apply the same transforms as skills (path rewrite, model mapping, tool stripping). Drop `tools:` from agent frontmatter.

**Why:** Antigravity supports agent subdirectories natively (confirmed by filesystem inspection: `~/.gemini/antigravity/skills/` structure). No flat renaming (unlike Cursor's `~/.cursor/agents/` requirement). No TOML sidecar generation (unlike Codex). This makes the Antigravity build the simplest of all three platform builds.

### DD4: Execution model -- sequential, non-interactive

**Chosen:** Treat Antigravity as non-interactive and sequential (same tier as Cursor).

**Why:** Antigravity is an IDE with async agent execution. The `env-compat.md` file already lists Antigravity in the non-interactive defaults section (line 155). Spawn blocks are replaced with "Execute inline sequentially" instructions. Interactive gates (`AskUserQuestion`) fall through to safest defaults with `[AUTO-DECISION]` annotations.

### DD5: Install path -- `~/.gemini/antigravity/skills/`

**Chosen:** Install to `~/.gemini/antigravity/skills/` with real files (not symlinks).

**Why:** Filesystem inspection confirmed this is the canonical path. Existing dead symlinks will be overwritten. Shared includes go to `~/.gemini/antigravity/shared/includes/`, rules to `~/.gemini/antigravity/rules/`.

### DD6: Semantic triggering -- keep using-zuvo as index

**Chosen:** Copy `using-zuvo` skill to Antigravity build. Optimize skill `description` fields for semantic activation (action verbs, domain keywords, max 200 chars). Do not remove the router -- it serves as a discovery/index skill.

**Why:** Antigravity uses the `description` field as a semantic trigger for auto-skill-selection. Zuvo's current descriptions are written for marketplace readability, not LLM activation. Rewriting descriptions in the build script is a low-cost optimization. The `using-zuvo` router stays as an index because users may ask "what zuvo skills are available" -- the router answers that.

### DD7: Config file references -- CLAUDE.md to GEMINI.md

**Chosen:** Replace all `CLAUDE.md` references with `GEMINI.md` in built output.

**Why:** Antigravity's global rules file is `~/.gemini/GEMINI.md` (confirmed on disk). Skills that reference "add to your CLAUDE.md" must say "add to your GEMINI.md" instead.

## Solution Overview

Create `scripts/build-antigravity-skills.sh` following the established build pipeline pattern:

```
Source: skills/*/SKILL.md + agents/*.md + shared/ + rules/
  |
  v  build-antigravity-skills.sh
  |
  v  Transform pipeline:
  |   1. Check for overlay (skills/<name>/antigravity/SKILL.antigravity.md)
  |   2. replace_paths()           ~/.claude/ -> ~/.gemini/antigravity/
  |   3. replace_model_refs()      sonnet->low, opus->high, haiku->flash
  |   4. replace_config_refs()     CLAUDE.md -> GEMINI.md
  |   5. strip_tool_names()        ToolSearch, AskUserQuestion, etc.
  |   6. transform_agent_frontmatter()  model mapping, drop tools:
  |   7. replace_spawn_blocks()    -> "Execute inline sequentially"
  |   8. normalize_unicode()
  |   9. validate_output()         grep for residual Claude tokens
  |
  v
dist/antigravity/
  skills/<name>/SKILL.md
  skills/<name>/agents/<agent>.md
  shared/includes/*.md
  rules/*.md
  scripts/adversarial-review.sh
  |
  v  install.sh antigravity
  |
  v
~/.gemini/antigravity/skills/    (real files, overwrites old symlinks)
~/.gemini/antigravity/shared/
~/.gemini/antigravity/rules/
```

## Detailed Design

### Transform Functions

#### `replace_paths()`

```
~/.claude/                          -> ~/.gemini/antigravity/
~/.claude/plugins/cache/...         -> ~/.gemini/antigravity/
CLAUDE_PLUGIN_ROOT                  -> GEMINI_HOME
../../shared/includes/              -> ../../shared/includes/  (unchanged -- relative)
```

Relative paths (`../../shared/includes/`) stay unchanged because the directory structure is preserved in the Antigravity dist.

#### `replace_model_refs()`

Operates on:
- Agent frontmatter: `model: sonnet` -> `model: gemini-3.1-pro-low`
- Prose tables: "Sonnet" -> "Gemini 3.1 Pro Low", "Opus" -> "Gemini 3.1 Pro High", "Haiku" -> "Gemini 3 Flash"
- Task dispatch syntax: `model: "sonnet"` -> `model: "gemini-3.1-pro-low"`

Does NOT replace:
- Model names inside adversarial review context (those are provider names, not dispatch targets)
- Model names in comparison tables that list multiple providers

#### `replace_config_refs()`

```
CLAUDE.md       -> GEMINI.md
.claude/        -> .gemini/          (in path references only)
Claude Code     -> Antigravity       (in platform name context only)
```

#### `strip_tool_names()`

Remove or replace references to Claude Code-specific tools:
- `ToolSearch(...)` -> removed (MCP discovery not available in same form)
- `AskUserQuestion` -> removed (non-interactive)
- `EnterPlanMode` / `ExitPlanMode` -> removed
- `TaskCreate` / `TaskUpdate` -> replaced with inline `STEP:` progress

#### `transform_agent_frontmatter()`

Input:
```yaml
---
name: code-explorer
description: "..."
model: sonnet
tools:
  - Read
  - Grep
  - Glob
---
```

Output:
```yaml
---
name: code-explorer
description: "..."
model: gemini-3.1-pro-low
---
```

Drop `tools:` list (Antigravity doesn't use it in frontmatter). Map model name.

#### `replace_spawn_blocks()`

Replace Claude Code agent spawn syntax with sequential inline instructions (same pattern as Cursor build). Detected by the existing awk parser that finds spawn blocks in SKILL.md files.

#### `normalize_unicode()`

Identical to Codex/Cursor builds. Normalizes invisible unicode characters that break markdown parsing.

#### `validate_output()`

Grep the entire `dist/antigravity/` for residual tokens that should not appear:
- `EnterPlanMode`, `ExitPlanMode`, `AskUserQuestion`, `ToolSearch`
- `CLAUDE_PLUGIN_ROOT`, `~/.claude/`
- `model: sonnet`, `model: haiku`, `model: opus` (in frontmatter context)
- `{plugin_root}` (unresolved placeholder)

Report count and file locations. Non-zero = build failure.

### Integration Points

#### `scripts/install.sh`

New function `install_antigravity()`:
1. Check `~/.gemini/antigravity/` exists (warn + skip if not)
2. Run `build-antigravity-skills.sh`
3. Remove old symlinks in `~/.gemini/antigravity/skills/` (replace with real files)
4. Copy `dist/antigravity/skills/` -> `~/.gemini/antigravity/skills/`
5. Copy `dist/antigravity/shared/` -> `~/.gemini/antigravity/shared/`
6. Copy `dist/antigravity/rules/` -> `~/.gemini/antigravity/rules/`

Extend case switch (line ~344): add `antigravity)` branch. Update `all)` to include antigravity.

#### `scripts/dev-push.sh`

Add antigravity build+install step when `~/.gemini/antigravity/` exists (conditional, same as Codex check).

#### `shared/includes/env-compat.md`

Add Antigravity column to all tables:

**Execution Models table:**

| Capability | Antigravity |
|---|---|
| Sub-agent dispatch | Not available -- single-agent, sequential |
| Concurrency | Sequential execution only |
| Model selection | Mapped to Gemini models (user can override in UI) |
| Progress reporting | Inline: `STEP: [name] [START\|DONE]` |
| User interaction | Not available -- use safest default |
| Agent instructions | Read `agents/*.md` yourself, execute sequentially |

**Environment-specific roots table:**

| Environment | Typical resolved path |
|---|---|
| Antigravity | `~/.gemini/antigravity/` |

**Interaction Defaults:** Already lists Antigravity (line 155). Verify consistency with new table entries.

#### `shared/includes/codesift-setup.md`

No structural change. Antigravity falls through to Degraded Mode (CodeSift unavailable) unless the user configures MCP manually. The `mcp_config.json` file exists but is empty.

#### `shared/includes/run-logger.md`

Add Antigravity detection:
```bash
if [ -n "$GEMINI_WORKSPACE" ] || ...; then
  LOG_PATH="memory/zuvo-runs.log"
else
  LOG_PATH="$HOME/.zuvo/runs.log"
fi
```

#### `shared/includes/platform-detection.md`

Add Antigravity to non-interactive environment lists where Codex and Cursor are already mentioned.

### Edge Cases

#### EC1: Dead symlinks at install target

The install function must handle existing symlinks at `~/.gemini/antigravity/skills/<name>`. Use `rm -f` before copy to remove symlinks, then copy real directories. Do not use `cp -r` over a symlink (it follows the link).

#### EC2: CodeSift unavailable

All 48 skills degrade gracefully when CodeSift is not found. The single-session warning fires once. No skill hard-fails.

#### EC3: Adversarial review script execution

If Antigravity sandboxes shell execution, `adversarial-review.sh` will fail. Skills detect this via exit code and print `[CROSS-REVIEW] No external provider available`. Degraded but functional.

#### EC4: Push gate enforcement

Skills `ship` and `deploy` must include Antigravity in the non-interactive push-skip list: "In non-interactive environments (Codex, Cursor, Antigravity): skip the push step entirely."

#### EC5: Overlay priority

If `skills/<name>/antigravity/SKILL.antigravity.md` exists, copy it verbatim instead of auto-transforming. Same pattern as Codex/Cursor overlays.

## Acceptance Criteria

1. `bash scripts/build-antigravity-skills.sh` produces `dist/antigravity/` with zero validation errors
2. `./scripts/install.sh antigravity` copies dist to `~/.gemini/antigravity/skills/` with real files (not symlinks)
3. `./scripts/install.sh all` includes Antigravity alongside Claude, Codex, and Cursor
4. All 48 skill SKILL.md files build without requiring manual overlay files
5. No residual Claude-specific tokens in built output (`ToolSearch`, `CLAUDE_PLUGIN_ROOT`, `~/.claude/`, `model: sonnet` in frontmatter)
6. `env-compat.md` has complete Antigravity column in every table, consistent with interaction defaults
7. Model mapping is correct: `sonnet->gemini-3.1-pro-low`, `opus->gemini-3.1-pro-high`, `haiku->gemini-3-flash`
8. Agent frontmatter has `tools:` list removed and model mapped
9. Spawn blocks replaced with sequential inline dispatch instructions
10. Old dead symlinks at `~/.gemini/antigravity/skills/` are replaced with real directories
11. `dev-push.sh` builds and installs to Antigravity when `~/.gemini/antigravity/` exists
12. Ship/deploy skills include Antigravity in push-skip list
13. `adversarial-review.sh` path references updated in built output

## Out of Scope

- **Antigravity plugin marketplace distribution** -- this spec covers local build+install only, not publishing to Open VSX or any Antigravity marketplace
- **MCP configuration for Antigravity** -- the empty `mcp_config.json` stays as-is; configuring CodeSift for Antigravity is a separate task
- **GEMINI.md rules injection** -- the user's `~/.gemini/GEMINI.md` is not modified; Zuvo rules go to `~/.gemini/antigravity/rules/`
- **Antigravity-specific skill overlays** -- no `antigravity/SKILL.antigravity.md` files are created in this spec; the auto-transform handles all 48 skills
- **Description optimization for semantic triggering** -- rewriting descriptions for better activation is a follow-up task after the build pipeline works
- **`antigravity-agent` provider for adversarial review** -- adding Antigravity CLI as a provider in `adversarial-review.sh` is a separate enhancement
- **`.antigravity-plugin/plugin.json` manifest** -- not needed for local install; only needed if we pursue marketplace distribution

## Open Questions

None -- all questions resolved during design dialogue.
