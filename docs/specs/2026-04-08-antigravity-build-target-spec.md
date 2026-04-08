# Antigravity Build Target -- Design Specification

> **spec_id:** 2026-04-08-antigravity-build-1215
> **topic:** Google Antigravity build target for Zuvo plugin
> **status:** Reviewed
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

**Why:** Antigravity supports agent subdirectories natively (confirmed by filesystem inspection: `~/.gemini/antigravity/skills/` structure). No flat renaming (unlike Cursor's `~/.cursor/agents/` requirement). No TOML sidecar generation (unlike Codex). This removes two major complexity sources from the build (TOML generation and flat agent renaming), though new functions like `replace_config_refs()` and broader model mapping add back some complexity.

### DD4: Execution model -- sequential, non-interactive

**Chosen:** Treat Antigravity as non-interactive and sequential (same tier as Cursor).

**Why:** Antigravity is an IDE with async agent execution. The `env-compat.md` file already lists Antigravity in the non-interactive defaults section (line 155). Spawn blocks are replaced with "Execute inline sequentially" instructions. Interactive gates (`AskUserQuestion`) fall through to safest defaults with `[AUTO-DECISION]` annotations.

### DD5: Install path -- `~/.gemini/antigravity/skills/`

**Chosen:** Install to `~/.gemini/antigravity/skills/` with real files (not symlinks).

**Why:** Filesystem inspection confirmed this is the canonical path. Existing dead symlinks will be overwritten. Shared includes go to `~/.gemini/antigravity/shared/includes/`, rules to `~/.gemini/antigravity/rules/`.

### DD6: Semantic triggering -- keep using-zuvo as index

**Chosen:** Copy `using-zuvo` skill to Antigravity build as-is. Descriptions are copied without modification in this spec. The `using-zuvo` router stays as a discovery/index skill.

**Why:** Antigravity uses the `description` field as a semantic trigger for auto-skill-selection (max 200 chars). However, optimizing descriptions for better semantic activation is a non-trivial content task that requires testing against Antigravity's actual triggering behavior. It is explicitly deferred to a follow-up task (see Out of Scope). The `using-zuvo` router stays because users may ask "what zuvo skills are available" -- the router answers that.

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
  |   6. adapt_agent_for_antigravity()  model mapping, drop tools:
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
{plugin_root}                       -> ~/.gemini/antigravity/
{plugin_root}/shared/               -> ~/.gemini/antigravity/shared/
{plugin_root}/rules/                -> ~/.gemini/antigravity/rules/
{plugin_root}/skills/               -> ~/.gemini/antigravity/skills/
../../shared/includes/              -> ../../shared/includes/  (unchanged -- relative)
```

Relative paths (`../../shared/includes/`) stay unchanged because the directory structure is preserved in the Antigravity dist. The `{plugin_root}` token and its subdirectory variants follow the same pattern as Cursor's `replace_paths()` (lines 46-53 of `build-cursor-skills.sh`).

#### `replace_model_refs()`

Operates on:
- Agent frontmatter: `model: sonnet` -> `model: gemini-3.1-pro-low`
- Prose tables: "Sonnet" -> "Gemini 3.1 Pro Low", "Opus" -> "Gemini 3.1 Pro High", "Haiku" -> "Gemini 3 Flash"
- Task dispatch syntax: `model: "sonnet"` -> `model: "gemini-3.1-pro-low"`

Does NOT replace:
- Model names inside adversarial review context (those are provider names, not dispatch targets)
- Model names in comparison tables that list multiple providers

#### `replace_config_refs()` -- NEW (no Cursor analog)

This function has no equivalent in `build-cursor-skills.sh` (Cursor keeps Claude references because it supports Claude natively). It must be authored from scratch.

```
CLAUDE.md       -> GEMINI.md
.claude/        -> .gemini/          (in path references only, handled by replace_paths())
Claude Code     -> Antigravity       (in platform name context, SKILL.md body only)
```

**CRITICAL SCOPE RESTRICTION:** The `Claude Code -> Antigravity` substitution MUST be scoped to SKILL.md body text only. It MUST NOT run on shared includes (`shared/includes/*.md`) or rules (`rules/*.md`), because those files describe ALL platforms in comparison tables. For example, `env-compat.md` has 12 "Claude Code" column headers and references that must remain intact. Running a global sed on shared files would produce broken tables like "Antigravity | Codex | Cursor | Antigravity".

Example sed patterns:

```bash
# Config file references (safe to run globally)
sed -i '' 's/CLAUDE\.md/GEMINI.md/g' "$file"

# Platform name — ONLY in skills, NOT shared includes
if [[ "$file" == *"/skills/"* && "$file" != *"/shared/"* ]]; then
  sed -i '' 's/Claude Code/Antigravity/g' "$file"
fi
```

The substitution targets only the platform name ("Claude Code"), never the model provider name ("Claude"). Model names like "Claude Sonnet 4.6" are handled by `replace_model_refs()` instead.

#### `strip_tool_names()`

Replace references to Claude Code-specific tools with Antigravity-appropriate prose (following Cursor build pattern of replacing with meaningful text, not deleting):
- `ToolSearch(...)` -> replace with "Check if MCP tools are available in this environment" (matches Cursor build lines 81-86)
- `AskUserQuestion(...)` -> replace with `[AUTO-DECISION: proceed with safest default]` (preserves decision-point context per DD4)
- `EnterPlanMode` / `ExitPlanMode` -> removed (no equivalent concept)
- `TaskCreate` / `TaskUpdate` -> replaced with inline `STEP:` progress reporting text

#### `adapt_agent_for_antigravity()` -- analogous to Cursor's `adapt_agent_for_cursor()`

This function replaces Cursor's `adapt_agent_for_cursor()` in the Antigravity build. The key difference: Cursor flattens agents into `dist/cursor/agents/` with skill-prefixed names; Antigravity keeps them in `skills/<name>/agents/` subdirectories. Both strip `tools:` and map model names.

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

Recursive grep across the entire `dist/antigravity/` tree for residual tokens that should not appear. Must recurse into `skills/*/agents/` subdirectories (unlike Cursor's validator which checks flat `agents/*.md`).

Targets:
- `EnterPlanMode`, `ExitPlanMode`, `AskUserQuestion`, `ToolSearch`
- `CLAUDE_PLUGIN_ROOT`, `~/.claude/`
- `model: sonnet`, `model: haiku`, `model: opus` (in YAML frontmatter context)
- `model: "sonnet"`, `model: "haiku"`, `model: "opus"` (quoted form in task dispatch syntax)
- `{plugin_root}` (unresolved placeholder)
- `Claude Code` (in skill body text only -- shared includes are exempt from this check)
- Prose model tier names: standalone "Sonnet", "Opus", "Haiku" in model dispatch context (not inside "Claude Sonnet" provider names)

Pattern: `grep -r` across `dist/antigravity/skills/` and `dist/antigravity/shared/`.

Report count and file locations. Non-zero = build failure.

### Integration Points

#### `scripts/install.sh`

New function `install_antigravity()`:
1. Guard: check `~/.gemini/antigravity/` exists (warn + `return 0` if not -- same pattern as `install_codex()` line 167)
2. Run `build-antigravity-skills.sh`
3. Remove old symlinks in `~/.gemini/antigravity/skills/` (replace with real files)
4. Copy `dist/antigravity/skills/` -> `~/.gemini/antigravity/skills/`
5. Copy `dist/antigravity/shared/` -> `~/.gemini/antigravity/shared/`
6. Copy `dist/antigravity/rules/` -> `~/.gemini/antigravity/rules/`
7. Copy `dist/antigravity/scripts/` -> `~/.gemini/antigravity/scripts/` (adversarial-review.sh, benchmark.sh)

Extend case switch (line ~362, not ~344): add `antigravity)` branch. Update `both|all)` to include `install_antigravity`. Update `Usage:` error message string to include `antigravity`.

#### `scripts/dev-push.sh`

No direct changes to `dev-push.sh` conditional logic needed. The Antigravity guard lives inside `install_antigravity()` itself (same pattern as `install_codex()` at line 167: `if [[ ! -d "$HOME/.codex" ]]; then warn...return 0; fi`). The `dev-push.sh` change is simply that `install.sh all` now includes Antigravity via the updated `both|all)` case branch.

#### `shared/includes/env-compat.md`

Add Antigravity as a 4th column to the existing Execution Models table (alongside Claude Code, Codex, Cursor). Do NOT create a separate section -- the table must be consistent.

Note: the Interaction Defaults section (line 155) already lists Antigravity as `(Codex App async mode, Cursor, Antigravity)`. The new column values must be consistent with this existing entry. Do not duplicate the Interaction Defaults entry.

**Execution Models table (new 4th column):**

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

The install function must handle existing symlinks in `~/.gemini/antigravity/skills/`, `~/.gemini/antigravity/shared/`, and `~/.gemini/antigravity/rules/` (the user's current install has a `rules/claude-rules` symlink). Use `rm -rf` on the target directories before copying to remove symlinks and stale content. Do not use `cp -r` over a symlink (it follows the link and may corrupt the source). Clean all three target directories, not just `skills/`.

#### EC2: CodeSift unavailable

All skills degrade gracefully when CodeSift is not found. The single-session warning fires once. No skill hard-fails.

#### EC3: Adversarial review script execution

If Antigravity sandboxes shell execution, `adversarial-review.sh` will fail. Skills detect this via exit code and print `[CROSS-REVIEW] No external provider available`. Degraded but functional.

#### EC4: Push gate enforcement

Skills `ship` and `deploy` must include Antigravity in the non-interactive push-skip list: "In non-interactive environments (Codex, Cursor, Antigravity): skip the push step entirely."

#### EC5: Overlay priority

If `skills/<name>/antigravity/SKILL.antigravity.md` exists, copy it verbatim instead of auto-transforming. Same pattern as Codex/Cursor overlays. Overlay files are hand-crafted for the target platform, so they are **exempt from validate_output()** checks -- they are expected to already have correct paths, model names, and tool references. The validation pass should skip files that came from overlays (track which files were overlayed during the build).

## Acceptance Criteria

1. `bash scripts/build-antigravity-skills.sh` produces `dist/antigravity/` with zero validation errors
2. `./scripts/install.sh antigravity` copies dist to `~/.gemini/antigravity/skills/` with real files (not symlinks)
3. `./scripts/install.sh all` includes Antigravity alongside Claude, Codex, and Cursor
4. All skill SKILL.md files (currently 49) build without requiring manual overlay files
5. No residual Claude-specific tokens in built output (`ToolSearch`, `CLAUDE_PLUGIN_ROOT`, `~/.claude/`, `model: sonnet` in frontmatter, `{plugin_root}`)
6. `env-compat.md` has complete Antigravity 4th column in every table, consistent with existing interaction defaults entry
7. Model mapping in frontmatter is correct: `sonnet->gemini-3.1-pro-low`, `opus->gemini-3.1-pro-high`, `haiku->gemini-3-flash`
8. Prose model tier names in skill body text and tables are replaced with Gemini equivalents ("Sonnet" -> "Gemini 3.1 Pro Low", etc.) except inside provider/adversarial-review context
9. Agent frontmatter has `tools:` list removed and model mapped (validated by recursive grep across `skills/*/agents/`)
10. Spawn blocks replaced with sequential inline dispatch instructions
11. Old dead symlinks at `~/.gemini/antigravity/skills/` are replaced with real directories
12. `install.sh` case switch updated: `antigravity)` branch added, `both|all)` includes `install_antigravity`, `Usage:` string updated
13. Ship/deploy skills include Antigravity in push-skip list
14. `adversarial-review.sh` copied to `dist/antigravity/scripts/` AND path references inside skill markdown updated to Antigravity paths

## Out of Scope

- **Antigravity plugin marketplace distribution** -- this spec covers local build+install only, not publishing to Open VSX or any Antigravity marketplace
- **MCP configuration for Antigravity** -- the empty `mcp_config.json` stays as-is; configuring CodeSift for Antigravity is a separate task
- **GEMINI.md rules injection** -- the user's `~/.gemini/GEMINI.md` is not modified; Zuvo rules go to `~/.gemini/antigravity/rules/`
- **Antigravity-specific skill overlays** -- no `antigravity/SKILL.antigravity.md` files are created in this spec; the auto-transform handles all skills (currently 49)
- **Description optimization for semantic triggering** -- rewriting descriptions for better activation is a follow-up task after the build pipeline works
- **`antigravity-agent` provider for adversarial review** -- adding Antigravity CLI as a provider in `adversarial-review.sh` is a separate enhancement
- **`.antigravity-plugin/plugin.json` manifest** -- not needed for local install; only needed if we pursue marketplace distribution

## Open Questions

1. **Model ID validation** -- The Gemini model IDs (`gemini-3.1-pro-low`, `gemini-3.1-pro-high`, `gemini-3-flash`) are based on the Antigravity UI model selector and web research. They have not been validated against Antigravity's internal model registry or API. If a model ID is invalid, agents will fail at dispatch. A runtime smoke test after first install is recommended.

2. **Model fallback chain** -- If a mapped Gemini model tier is unavailable in a user's environment, there is no fallback. Consider adding fallback order: `gemini-3.1-pro-high` -> `gemini-3.1-pro-low` -> `gemini-3-flash`. Deferred to implementation.

3. **AC8 prose exclusion rules** -- The "adversarial/provider context" exclusion for prose model name validation is not machine-checkable. Implementation should define explicit file-scope or marker-based exclusions rather than context-sensitive grep patterns.

4. **Spawn block parser** -- The spec references "the existing awk parser" for spawn blocks, but `build-cursor-skills.sh` may implement this differently than expected. The implementer should examine the actual Cursor spawn block replacement code and adapt, not assume a reusable parser exists.

5. **BSD vs GNU sed** -- The example sed patterns use macOS BSD syntax (`sed -i ''`). If cross-platform builds are needed (CI/CD on Linux), a sed wrapper or alternative approach will be required.
