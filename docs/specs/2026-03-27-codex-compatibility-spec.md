# Codex Compatibility Layer -- Design Specification

> **Date:** 2026-03-27
> **Status:** Approved
> **Author:** zuvo:brainstorm

## Problem Statement

Zuvo is a 33-skill Claude Code plugin with multi-agent workflows, quality gates, and structured development pipelines. It currently runs exclusively on Claude Code. OpenAI Codex has adopted the same SKILL.md open standard (agentskills.io) and has a native plugin system (`.codex-plugin/plugin.json`), TOML-based agent dispatch, and MCP support. Zuvo's skill format is already cross-platform compatible, but the surrounding infrastructure (hooks, agent dispatch, tool references, interactive gates) is Claude Code-specific.

Without Codex support, Zuvo is limited to a single platform while the SKILL.md ecosystem grows across 30+ platforms. Competitors like everything-claude-code (100k+ stars) already ship cross-platform.

## Design Decisions

### D1: Distribution -- dual-manifest in single repo

**Chosen:** Single repository with both `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` pointing at the same `skills/` directory.

**Rationale:** This is the dominant industry pattern (fcakyon/claude-codex-settings, compound-engineering-plugin). SKILL.md is natively compatible -- zero conversion needed for skill files. Platform-specific differences are isolated to manifests and build output.

**Alternatives considered:**
- Separate `zuvo-codex` repo -- rejected due to maintenance burden and drift risk
- Build-script-only with no committed Codex manifest -- rejected; `.codex-plugin/` is needed for Codex plugin discovery

### D2: Build pipeline -- adapted from claude-code-toolkit

**Chosen:** Copy and adapt `build-codex-skills.sh` (670 lines) from claude-code-toolkit into `zuvo-plugin/scripts/`. The script transforms skill files for Codex compatibility and generates TOML agent configs. Output goes to `dist/codex/`.

**Rationale:** zuvo-plugin replaces claude-code-toolkit as the single source of truth. The toolkit's build script is production-tested and handles: unicode normalization, path remapping, Task tool -> TOML agent prose conversion, model mapping, ToolSearch removal, and output validation.

**Adaptations needed (non-trivial):**
- Add ToolSearch -> direct `mcp__codesift__*` replacement logic (not in existing script)
- Add `gpt-5.3-codex` model tier and `model_reasoning_effort` TOML field generation
- Add logic to distinguish coding-opus vs reasoning-opus agents (via `reasoning: true` frontmatter flag in agent .md files)
- Add `[AUTO-DECISION]` injection for brainstorm/design skills
- Add `.codex-plugin/plugin.json` and `.mcp.json` generation
- Add support for 6 pipeline skills (brainstorm, plan, execute, worktree, receive-review, using-zuvo) + their 12 agents
- Add 4 new shared includes (run-logger, tdd-protocol, verification-protocol, quality-gates)
- Change TOML description suffix from `Spawned by /<skill>.` to `Spawned by zuvo:<skill>.`

### D3: Router injection -- implicit skill invocation

**Chosen:** The `using-zuvo` skill uses `allow_implicit_invocation: true` in `agents/openai.yaml`. Codex auto-activates the skill when task description matches, replacing Claude Code's SessionStart hook.

**Rationale:** Codex does NOT scan plugin directories for AGENTS.md (only `~/.codex/AGENTS.md` and project root). Implicit skill invocation is the Codex-native equivalent of Claude Code's auto-routing. The skill's `description` field controls when it activates.

**Alternatives considered:**
- AGENTS.md in plugin root -- rejected; Codex does not read it from plugin dirs
- User's personal `~/.codex/AGENTS.md` injection -- rejected; requires manual setup
- TOML agent with `developer_instructions` containing the router -- viable fallback; **promote to primary if `allow_implicit_invocation` is not a real Codex API field** (see Open Questions OQ1)

### D4: Multi-turn dialogue on Codex -- best-judgment draft

**Chosen:** Skills requiring multi-turn dialogue (brainstorm, design) operate autonomously on Codex, producing complete output with every design decision annotated as `[AUTO-DECISION]`. The user reviews and edits the artifact after the fact.

**Rationale:** Codex CLI is interactive (Enter/Tab for mid-task steering), but Codex App runs async. The `[AUTO-DECISION]` pattern works for both: interactive CLI users see the flags and can intervene; async App users review the spec post-completion. This preserves brainstorm's value (full spec output) without requiring live Q&A.

**Format:**
```markdown
### API approach
**[AUTO-DECISION]** Chosen: Event-driven with queue
Rationale: Existing notification service uses events; consistent with codebase patterns.
Alternatives considered: Direct service call, WebSocket push.
--> Review this decision before running zuvo:plan.
```

### D5: Model mapping -- three-tier with reasoning effort

**Chosen:**
| Claude model | Codex model | Notes |
|-------------|-------------|-------|
| `haiku` | `gpt-5.4-mini` | Fast/cheap subagents |
| `sonnet` | `gpt-5.4` | General-purpose default |
| `opus` | `gpt-5.3-codex` | Coding-heavy skills (implement, refactor) |
| `opus` (reasoning) | `gpt-5.4` + `model_reasoning_effort = "xhigh"` | Reasoning-heavy skills (architecture, spec review) |

**Rationale:** `gpt-5.3-codex` is OpenAI's coding specialist (strongest for pure software engineering). `gpt-5.4` with `xhigh` reasoning effort is better for analytical tasks. The toolkit's current mapping (`opus -> gpt-5.4`) under-utilizes `gpt-5.3-codex`.

**Implementation detail:** The build script determines the mapping via a `reasoning: true` frontmatter flag in agent `.md` files. Agents with this flag get `gpt-5.4` + `model_reasoning_effort = "xhigh"`. Agents without it (default) get `gpt-5.3-codex`. Example agents that should be reasoning-heavy: `spec-reviewer`, `plan-reviewer`, `architect`, `quality-reviewer`.

### D6: Interaction defaults -- Codex App only

**Chosen:** Explicit defaults for non-interactive environments (Codex App async mode). Codex CLI remains fully interactive.

| Gate type | Codex App default |
|-----------|-------------------|
| Plan/spec approval | Proceed automatically, annotate `[AUTO-APPROVED on Codex]` |
| Commit confirmation | Commit automatically, NEVER push |
| Task dependency unavailable | Log issue, skip task, continue with next |
| Clarifying questions | Best-judgment + `[AUTO-DECISION]` annotation |

**Rationale:** Codex CLI supports mid-task user interaction (Enter to inject, Tab to queue). The "safest default" pattern in env-compat.md should only activate when `AskUserQuestion` equivalent is truly unavailable (Codex App async). The existing env-compat.md is too broad ("Codex: not available") -- it should distinguish CLI vs App.

### D7: ToolSearch replacement -- direct MCP with fallback

**Chosen:** Build script replaces `ToolSearch(query="codesift", max_results=20)` blocks with direct `mcp__codesift__*` tool references, preserving the existing fallback chain: MCP tools -> CLI (`codesift search ...`) -> Grep/Read.

**Rationale:** Codex uses the same `mcp__<server>__<tool>` naming convention as Claude Code. MCP tools are available at session start if configured in `config.toml`. No ToolSearch/deferred-loading concept exists in Codex. The fallback guard is still needed because CodeSift may not be installed.

### D8: Run logger -- environment-aware path

**Chosen:** Conditional log path:
1. Codex App (cloud sandbox): `memory/zuvo-runs.log` (project-local, persists via git)
2. Codex CLI (local): `~/.zuvo/runs.log` (user's real home)
3. Write fails: skip silently

**Rationale:** Codex App's `~` is ephemeral (resets on branch checkout, cached up to 12h). Codex CLI's `~` is the real home directory but `workspace-write` sandbox blocks writes outside workspace by default. Project-local fallback ensures persistence in both cases.

### D9: Plugin manifest -- `.codex-plugin/plugin.json`

**Chosen:** Codex plugin manifest mirroring Claude Code's structure:
```json
{
  "name": "zuvo",
  "version": "1.0.0",
  "description": "Multi-agent skill ecosystem for structured software development...",
  "author": { "name": "Zuvo", "email": "hello@zuvo.dev" },
  "homepage": "https://zuvo.dev",
  "license": "MIT",
  "skills": "./skills/",
  "mcpServers": "./.mcp.json"
}
```

**Rationale:** Matches confirmed Codex plugin.json spec. `"skills"` field is a path pointer to the skills directory. `"mcpServers"` references a separate `.mcp.json` file (not inline) for optional CodeSift bundling.

## Solution Overview

```
zuvo-plugin/
  .claude-plugin/plugin.json     <-- Claude Code manifest (existing)
  .codex-plugin/plugin.json      <-- Codex manifest (NEW)
  .mcp.json                      <-- Optional MCP config for CodeSift (NEW)
  skills/
    using-zuvo/
      SKILL.md                   <-- Shared (read by both platforms)
      agents/
        openai.yaml              <-- Codex implicit invocation config (NEW)
    build/SKILL.md               <-- Shared
    review/SKILL.md              <-- Shared
    brainstorm/
      SKILL.md                   <-- Shared
      agents/
        code-explorer.md         <-- Shared agent instructions
        openai.yaml              <-- Codex agent metadata (NEW)
    [... 30 more skills ...]
  shared/includes/
    env-compat.md                <-- Updated with Codex CLI vs App distinction
    codex-agent-registry.md      <-- TOML generation manifest (NEW, from toolkit)
    [... existing includes ...]
  rules/                         <-- Shared (unchanged)
  hooks/                         <-- Claude Code only (unchanged)
  scripts/
    release.sh                   <-- Extended with Codex build step
    build-codex-skills.sh        <-- Codex build pipeline (NEW, from toolkit)
  dist/
    codex/                       <-- Build output (gitignored)
      skills/                    <-- Codex-adapted skill files
      agents/                    <-- Generated TOML configs (~35 files)
      rules/                     <-- Codex-adapted rules
      .codex-plugin/plugin.json
      .mcp.json
```

**Flow:**
1. Developer works on skills in `skills/` -- one source of truth
2. `scripts/build-codex-skills.sh` transforms for Codex: strips Claude-Code-specific tool refs, replaces Task() with TOML agent prose, normalizes unicode, remaps paths, generates TOMLs
3. Output lands in `dist/codex/` -- a self-contained Codex plugin
4. `scripts/release.sh` bumps version in both manifests, builds Codex dist, pushes both

**Claude Code users:** Install via marketplace as before. No change.
**Codex users:** Install from `dist/codex/` directory or via marketplace.json reference.

## Detailed Design

### Build Pipeline (`scripts/build-codex-skills.sh`)

Adapted from claude-code-toolkit's 670-line build script. Core transformations:

| Step | What it does | Source reference |
|------|-------------|-----------------|
| 1. Unicode normalization | `--` -> `--`, `->` -> `->`, emoji -> ASCII | toolkit `normalize_unicode()` |
| 2. Path remapping | `~/.claude/` -> `~/.codex/`, `CLAUDE_PLUGIN_ROOT` -> `CODEX_HOME` | toolkit `replace_paths()` |
| 3. Task tool -> TOML prose | `Task(model: "sonnet", type: "Explore", ...)` -> `Spawn Codex agent: **skill-name**` | toolkit `transform_skill_for_codex()` |
| 4. Tool name stripping | `ToolSearch`, `TaskCreate`, `TaskUpdate`, `SendMessage`, `TeamCreate` -> plain English | toolkit `strip_tool_names()` |
| 5. Section stripping | Remove `Progress Tracking`, `Model Routing`, `Path Resolution` sections | toolkit pattern |
| 6. TOML generation | For each `agents/*.md` with `description:` frontmatter -> `.toml` config | toolkit `generate_agent_toml()` |
| 7. Model mapping | `haiku` -> `gpt-5.4-mini`, `sonnet` -> `gpt-5.4`, `opus` -> `gpt-5.3-codex` | Updated from toolkit |
| 8. Sandbox mapping | `Write`/`Edit` in tools -> `sandbox_mode = "full"`, else `read-only` | toolkit pattern |
| 9. Validation | Check for residual Claude-Code tool names, untransformed paths, wrong models | toolkit pattern |

**New additions vs toolkit:**
- Pipeline skill support (brainstorm, plan, execute + 12 agents)
- `.codex-plugin/plugin.json` generation
- `.mcp.json` generation (optional CodeSift config)
- `using-zuvo/agents/openai.yaml` generation
- Shared includes: run-logger.md, tdd-protocol.md, verification-protocol.md, quality-gates.md
- `[AUTO-DECISION]` injection logic for brainstorm/design skills

### TOML Agent Generation

The build script generates one `.toml` file per agent in `dist/codex/agents/`:

```toml
# Example: dist/codex/agents/brainstorm-code-explorer.toml
name = "brainstorm-code-explorer"
description = "Scans codebase for relevant modules, patterns, and blast radius. Spawned by zuvo:brainstorm."
model = "gpt-5.4"
sandbox_mode = "read-only"
developer_instructions = """
You are a code-explorer agent for the zuvo:brainstorm skill.
Read your full instructions at ~/.codex/skills/brainstorm/agents/code-explorer.md
NEVER modify files -- analyze and report only.
"""
```

**Naming convention:** `<skill-prefix>-<agent-name>` (e.g., `brainstorm-code-explorer`, `execute-implementer`, `review-behavior-auditor`).

**Expected count:** ~35 TOML files (12 pipeline agents + ~23 from toolkit skills that have agents/ dirs).

### Codex Skill Auto-Discovery (`agents/openai.yaml`)

Each skill that needs Codex-specific metadata gets an `agents/openai.yaml` sidecar:

```yaml
# skills/using-zuvo/agents/openai.yaml
policy:
  allow_implicit_invocation: true
```

This is the Codex equivalent of Claude Code's SessionStart hook. The `using-zuvo` skill activates implicitly when the user's intent matches its description, providing the routing table.

For other skills, `openai.yaml` is optional -- Codex discovers skills by scanning the `skills/` directory declared in `plugin.json`.

### env-compat.md Updates

Add a new section distinguishing Codex CLI from Codex App:

```markdown
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
```

### Release Workflow

Extended `scripts/release.sh`:

```bash
# Existing steps (unchanged):
# 1. Parse bump type (patch/minor/major) and commit message
# 2. Update version in package.json and .claude-plugin/plugin.json
# 3. Commit, push, tag the zuvo repo
# 4. Update SHA in zuvo-marketplace

# New steps:
# 5. Update version in .codex-plugin/plugin.json
# 6. Run build-codex-skills.sh -> dist/codex/
# 7. Update Codex marketplace.json (when self-serve publishing available)
```

### Optional MCP Config (`.mcp.json`)

Bundled with the Codex plugin for optional CodeSift integration:

```json
{
  "codesift": {
    "command": "npx",
    "args": ["-y", "codesift-mcp"],
    "startup_timeout_sec": 30,
    "tool_timeout_sec": 60
  }
}
```

Users who install the plugin get CodeSift auto-configured. Skills that reference `mcp__codesift__*` tools work out of the box.

## Integration Points

### Files created (new)
- `.codex-plugin/plugin.json` -- Codex plugin manifest
- `.mcp.json` -- Optional MCP server config
- `scripts/build-codex-skills.sh` -- Build pipeline (from toolkit)
- `shared/includes/codex-agent-registry.md` -- TOML generation manifest (from toolkit)
- `skills/using-zuvo/agents/openai.yaml` -- Implicit invocation config
- `dist/codex/` -- Build output directory (gitignored)

### Files modified
- `shared/includes/env-compat.md` -- Add Codex CLI vs App distinction, interaction defaults
- `scripts/release.sh` -- Add Codex build and version sync steps
- `.gitignore` -- Add `dist/`
- `README.md` -- Add Codex installation section
- `docs/getting-started.md` -- Add Codex installation instructions
- `docs/configuration.md` -- Add Codex plugin structure, shared includes update

### Files unchanged
- All 33 `skills/*/SKILL.md` files -- the build script transforms copies, not originals
- `rules/` -- copied as-is by build script
- `hooks/` -- Claude Code only, untouched
- `.claude-plugin/plugin.json` -- unchanged

## Edge Cases

### E1: CodeSift not installed on Codex
Skills that use `mcp__codesift__*` tools check availability at skill start. If not configured: fall back to CLI (`codesift search ...`), then Grep/Read. The `.mcp.json` bundled with the plugin provides auto-configuration, but users may not have `codesift-mcp` installed globally.

**Handling:** Preserve the existing three-tier fallback (MCP -> CLI -> Grep) in the Codex-adapted skill files. The build script must NOT strip the fallback logic, only the ToolSearch discovery wrapper.

### E2: Codex App ephemeral home directory
`~/.zuvo/runs.log` disappears when the cloud container resets.

**Handling:** env-compat.md instructs skills to detect environment and use `memory/zuvo-runs.log` (project-local) in cloud/sandbox environments.

### E3: max_threads=6 constraint
Codex caps concurrent subagents at 6. Current peak: 4 agents (build skill Phase 1).

**Handling:** No change needed today. Add a comment in codex-agent-registry.md noting the 6-thread limit. If future skills need more, they must batch agents.

### E4: max_depth=1 constraint
Codex default prevents agents from spawning sub-agents (depth 2+).

**Handling:** Zuvo's architecture is depth-1 (orchestrator -> subagents, no deeper). Document this as a constraint in env-compat.md.

### E5: brainstorm produces spec without user dialogue on Codex App
A user invokes brainstorm async and receives a spec with decisions they didn't make.

**Handling:** Every `[AUTO-DECISION]` includes rationale, alternatives, and an explicit instruction: "Review this decision before running zuvo:plan." The spec status is "Draft (auto-generated)" not "Approved."

### E6: Skill body exceeds 500-line Codex budget
Some zuvo skills (execute, brainstorm) are 300+ lines. Codex recommends 500-line max.

**Handling:** Current skills are within budget. The build script validates line count and warns if a skill exceeds 500 lines after transformation.

### E7: TOML agent name collisions
If the user has personal agents with the same name as zuvo's generated agents.

**Handling:** All zuvo agent names are prefixed with the skill name (e.g., `brainstorm-code-explorer`, not just `code-explorer`). This provides namespace isolation.

## Acceptance Criteria

1. Running `scripts/build-codex-skills.sh` produces a complete `dist/codex/` directory with all 33 skills adapted, ~35 TOML agent configs generated, rules copied, and `.codex-plugin/plugin.json` present.

2. The build script's validation step passes with zero residual Claude-Code tool names (`ToolSearch`, `TaskCreate`, `TaskUpdate`, `SendMessage`, `TeamCreate`), zero untransformed `~/.claude/` paths, and zero wrong model names in TOML files.

3. Every generated TOML agent config has: `name` (prefixed), `description` (with "Spawned by zuvo:<skill>"), `model` (mapped correctly), `sandbox_mode` (read-only or full based on tools), and `developer_instructions` (pointing to the correct agent .md file path).

4. `dist/codex/skills/using-zuvo/agents/openai.yaml` contains `allow_implicit_invocation: true`.

5. `dist/codex/skills/brainstorm/SKILL.md` contains `[AUTO-DECISION]` annotation instructions in the Phase 2 Design Dialogue section. The skill does NOT reference `AskUserQuestion` or `Skill` tool.

6. `shared/includes/env-compat.md` distinguishes Codex CLI (interactive) from Codex App (async) and lists explicit defaults for 4 gate types (approval, commit, dependency, questions).

7. `.codex-plugin/plugin.json` is valid JSON with `name`, `version`, `description`, `skills` field pointing to `"./skills/"`, and `mcpServers` pointing to `"./.mcp.json"`.

8. `scripts/release.sh` updates version in both `.claude-plugin/plugin.json` AND `.codex-plugin/plugin.json`, then runs the Codex build step.

9. All Codex-adapted skill files in `dist/codex/skills/` preserve the CodeSift fallback chain (MCP -> CLI -> Grep) without ToolSearch wrapper.

10. All `ToolSearch(query="codesift", max_results=20)` blocks in source skills are replaced with direct `mcp__codesift__*` tool references in the Codex output. Zero residual `ToolSearch` calls in `dist/codex/`.

11. The model mapping produces: `haiku` -> `gpt-5.4-mini`, `sonnet` -> `gpt-5.4`, `opus` (coding) -> `gpt-5.3-codex`, `opus` (reasoning) -> `gpt-5.4` with `model_reasoning_effort = "xhigh"`.

12. No existing Claude Code functionality is broken: all 33 skills work identically on Claude Code after the changes. The `.claude-plugin/plugin.json`, `hooks/`, and `skills/` source files are unchanged.

13. `dist/codex/` is listed in `.gitignore` -- build output is not committed.

14. `.codex-plugin/plugin.json` is committed at the repo root (not in `dist/`) -- it is the Codex plugin manifest discoverable by the Codex plugin system.

15. Documentation (README.md, getting-started.md, configuration.md) includes Codex installation instructions.

## Out of Scope

- **Cursor compatibility** -- future work; different adaptation layer (no SKILL.md native support, needs `.mdc` conversion)
- **Codex marketplace self-serve publishing** -- not yet available from OpenAI; will add when it ships
- **Gemini CLI / other platforms** -- future work based on the same SKILL.md standard
- **Rewriting skills for Codex** -- the build script transforms; skills are maintained in Claude Code format as source of truth
- **Testing zuvo on Codex** -- requires a Codex environment; tracked as a follow-up
- **Codex App-specific optimizations** -- async task chunking, checkpoint persistence; future enhancement
- **Deprecating claude-code-toolkit** -- separate decision; this spec only covers copying the build infrastructure

## Open Questions

### OQ1 (P0): Verify `allow_implicit_invocation` in Codex

The `allow_implicit_invocation: true` field in `agents/openai.yaml` is the sole mechanism for router injection on Codex (D3). This field was reported by research agents as a Codex API feature but has no existing implementation in either codebase. **Before implementing D3, verify this field against a real Codex install or the Codex plugin documentation.**

**Fallback if field does not exist:** Promote the TOML agent approach -- create a `zuvo-router` agent with `developer_instructions` containing the full routing table from `using-zuvo/SKILL.md`. This is less elegant but functionally equivalent.

### OQ2 (P1): Validate `.codex-plugin/plugin.json` field names

The `"skills"` and `"mcpServers"` fields in the proposed Codex manifest (D9) are based on research agent reports but have no corroborating artifact in either codebase. **Before the first release that publishes a Codex manifest, validate these field names against the actual Codex plugin specification at developers.openai.com/codex/plugins.**

If field names differ, adjust the manifest accordingly. The remaining spec is unaffected -- the skills directory structure and TOML generation are independent of the manifest format.
