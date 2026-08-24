#!/bin/bash
# Build Kimi Code-adapted skills from zuvo-plugin source skills.
#
# Kimi Code (moonshotai/kimi-code) is the CLOSEST of all non-Claude targets — it is
# effectively a Claude Code superset for our purposes. Contracts below were read out of
# the shipped binary on v0.34.0 and re-confirmed on v0.35.0 (it self-updates), so they
# are stable across at least one minor. Re-verify them if a build starts producing
# skills Kimi silently ignores:
#
#   | Capability      | Kimi Code                                                      |
#   |-----------------|----------------------------------------------------------------|
#   | Skills          | ~/.kimi-code/skills/<name>/SKILL.md  (dir with SKILL.md = bundle)|
#   | Sub-agents      | YES — `Agent` tool: prompt/description/subagent_type/            |
#   |                 | run_in_background. Builtin types: agent, coder, explore, plan.    |
#   |                 | Custom profiles come from ~/.kimi-code/agents/ — FLAT namespace   |
#   |                 | (discoverAgentFiles builds a Map byName), so agents are flattened |
#   |                 | with a skill prefix exactly like the Cursor build.                |
#   | Agent frontmatter| name, description, tools, disallowedTools, whenToUse, type,      |
#   |                 | subagents, override, model_preference ("primary" | "secondary")   |
#   | Hooks           | ALL zuvo events exist: PreToolUse, PostToolUse, SessionStart,     |
#   |                 | Stop, StopFailure, SubagentStop, PreCompact, UserPromptSubmit.    |
#   |                 | Config lives in ~/.kimi-code/config.toml as `[[hooks]]` tables    |
#   |                 | (event/matcher/command/timeout) — NOT the nested JSON shape.      |
#   | Project config  | AGENTS.md (not CLAUDE.md)                                        |
#
# So — unlike the Cursor/Antigravity builds — this one does NOT degrade parallel
# sub-agent dispatch to inline-sequential execution. Preserving that is the whole
# point: zuvo's audit skills are multi-agent by design.
#
# NOT used: Kimi's native plugin system (kimi.plugin.json / .kimi-plugin/plugin.json
# registered in $KIMI_CODE_HOME/plugins/installed.json). That is a central registry
# file of exactly the kind whose staleness has bitten this repo before (see the
# `installed_plugins.json` gotcha in CLAUDE.md). The user-scope auto-discovery dirs
# have no registry to corrupt, which is why every other zuvo target uses them too.
#
# Template: build-cursor-skills.sh (flat agents) + build-antigravity-skills.sh (validation)
#
# Usage: bash scripts/build-kimi-skills.sh [plugin-dir]

set -euo pipefail

PLUGIN_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# DIST root is env-overridable (B-DIST-BUILD-RACE). Every builder wrote to $PLUGIN_DIR/dist/<p>,
# and reviewer-model-builds.bats `rm -rf`s that tree in its per-test setup() — so one test file
# could truncate a directory another was asserting against. It went red about twice in ten suite
# runs and produced TWO wrong conclusions in one session: a bisect that blamed an innocent registry
# change, and a "regression" that was not one. Both were only caught by re-running in a git
# worktree with its own dist/. Unset, this is exactly the previous path, so install.sh is unchanged.
DIST="${ZUVO_DIST_ROOT:-$PLUGIN_DIR/dist}/kimi"

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"

echo "Building Kimi Code skills..."
echo "  Source: $PLUGIN_DIR"
echo "  Output: $DIST"
echo ""

# Clean previous build
rm -rf "$DIST"
mkdir -p "$DIST/skills" "$DIST/agents"

# --- Unicode Normalization (reusable) ---
normalize_unicode() {
  sed \
    -e 's/—/--/g' \
    -e 's/–/-/g' \
    -e 's/→/->/g' \
    -e 's/✅/[x]/g' \
    -e 's/❌/[ ]/g' \
    -e 's/━/-/g' \
    -e 's/═/=/g' \
    -e 's/≤/<=/g' \
    -e 's/≥/>=/g' \
    -e 's/≠/!=/g' \
    -e 's/⚠️/[!]/g' \
    -e 's/⚠/[!]/g' \
    -e 's/⏭️/[SKIP]/g' \
    -e 's/⏭/[SKIP]/g' \
    -e 's/❓/[?]/g'
}

# --- Platform Blocks ---
# Shared prose carries per-platform sections delimited by <!-- PLATFORM:X --> markers.
# Drop every other platform's block and unwrap our own, exactly as the Codex and Cursor
# builds do. Without this, a Kimi run would read Codex's "single-agent hard rule" section
# and degrade itself on advice written for a harness with no sub-agents.
strip_platform_blocks() {
  sed \
    -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
    -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
    -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
    -e '/<!-- PLATFORM:KIMI -->/d' \
    -e '/<!-- \/PLATFORM:KIMI -->/d'
}

# --- Path Replacement (Kimi) ---
# CRITICAL: Replace ALL relative paths (../../) with absolute ~/.kimi-code/ paths.
# Relative paths work in Claude Code (plugin resolves from SKILL.md location) but NOT in
# Kimi/Codex/Cursor, where the agent reads instructions and resolves from CWD.
# NOTE: ~/.zuvo/ (retros, runlog, helper binaries) is deliberately NOT rewritten — it is
# shared HOME state across every platform, not a per-platform install root.
replace_paths() {
  sed \
    -e 's|{plugin_root}/shared/|~/.kimi-code/shared/|g' \
    -e 's|{plugin_root}/rules/|~/.kimi-code/rules/|g' \
    -e 's|{plugin_root}/skills/|~/.kimi-code/skills/|g' \
    -e 's|{plugin_root}|~/.kimi-code|g' \
    -e 's|CLAUDE_PLUGIN_ROOT|KIMI_CODE_HOME|g' \
    -e 's|~/\.claude/plugins/cache/zuvo-marketplace/zuvo/[^/]*/scripts/adversarial-review\.sh|~/.kimi-code/scripts/adversarial-review.sh|g' \
    -e 's|~/\.claude/plugins/cache/zuvo-marketplace/zuvo/[^/]*/|~/.kimi-code/|g' \
    -e 's|\$HOME/\.claude/|$HOME/.kimi-code/|g' \
    -e 's|~/\.claude/|~/.kimi-code/|g' \
    -e 's|../../shared/includes/|~/.kimi-code/shared/includes/|g' \
    -e 's|../../shared/|~/.kimi-code/shared/|g' \
    -e 's|../../scripts/|~/.kimi-code/scripts/|g' \
    -e 's|../../rules/|~/.kimi-code/rules/|g' \
    -e 's|../../skills/|~/.kimi-code/skills/|g'
}

# --- Model Replacement (Kimi — two abstract lanes) ---
# Kimi's agent frontmatter takes `model_preference`, which the loader validates as
# exactly "primary" or "secondary" (any other value is a hard parse error). It is a
# LANE, not a model id, so zuvo's tiers collapse onto two lanes:
#   opus / sonnet / review-primary -> primary    (session's main model, k3 by default)
#   haiku / review-alt             -> secondary  (the cheap lane)
# Mirrors the Cursor mapping (sonnet -> inherit, haiku -> fast) rather than inventing
# concrete kimi-code/* ids, which would go stale the moment Moonshot ships a new model.
replace_model_refs() {
  sed \
    -e 's/model: review-primary/model_preference: primary/g' \
    -e 's/model: review-alt/model_preference: secondary/g' \
    -e 's/model: sonnet/model_preference: primary/g' \
    -e 's/model: opus/model_preference: primary/g' \
    -e 's/model: haiku/model_preference: secondary/g' \
    -e 's/model: "review-primary"/model_preference: "primary"/g' \
    -e 's/model: "review-alt"/model_preference: "secondary"/g' \
    -e 's/model: "sonnet"/model_preference: "primary"/g' \
    -e 's/model: "opus"/model_preference: "primary"/g' \
    -e 's/model: "haiku"/model_preference: "secondary"/g' \
    -e 's/Model | Sonnet/Model | primary lane/g' \
    -e 's/Model | Opus/Model | primary lane/g' \
    -e 's/Model | Haiku/Model | secondary lane/g' \
    -e 's/| Sonnet |/| primary lane |/g' \
    -e 's/| Opus |/| primary lane |/g' \
    -e 's/| Haiku |/| secondary lane |/g' \
    -e 's/-> Sonnet/-> primary lane/g' \
    -e 's/-> Opus/-> primary lane/g' \
    -e 's/-> Haiku/-> secondary lane/g'
}

replace_reviewer_lane_refs_kimi() {
  perl -pe 's/\breview-primary\b/primary lane/g; s/\breview-alt\b/secondary lane/g'
}

# --- Config Reference Replacement (Kimi) ---
# CRITICAL: "Claude Code" -> "Kimi Code" ONLY in skill body text, NOT shared includes
# (the includes are cross-platform prose and several of them name Claude Code as one
# provider among several — rewriting those would state falsehoods).
replace_config_refs() {
  local file="$1"
  # Always safe: project config file name (Kimi reads AGENTS.md, the open standard)
  sed_i 's/CLAUDE\.md/AGENTS.md/g' "$file"
  # Platform name — only in skills, NOT shared includes
  if [[ "$file" == *"/skills/"* ]] && [[ "$file" != *"/shared/"* ]]; then
    sed_i 's/Claude Code/Kimi Code/g' "$file"
  fi
}

# --- Tool Name Adaptation (Kimi) ---
# Kimi's tool surface: Agent, Skill, Bash, Read, Write, Edit, Glob, Grep, WebSearch,
# WebFetch, TodoList, AskUserQuestion, EnterPlanMode, ExitPlanMode.
# So — unlike Cursor/Antigravity — AskUserQuestion and the plan-mode tools SURVIVE
# verbatim. Only genuinely absent tools are rewritten:
#   Task tool  -> Agent tool   (Kimi's subagent tool is named Agent)
#   TodoWrite  -> TodoList
#   MultiEdit  -> Edit
#   Team*/SendMessage -> dropped (no multi-session teams in Kimi)
#   ToolSearch -> neutral MCP-availability check (Kimi's `select_tools` has a
#                 different contract; asserting the Claude one would be wrong)
adapt_tool_names() {
  sed \
    -e 's/`TodoWrite`/`TodoList`/g' \
    -e 's/TodoWrite/TodoList/g' \
    -e 's/`TaskCreate`/`TodoList`/g' \
    -e 's/`TaskUpdate`/`TodoList`/g' \
    -e 's/`TaskList`/`TodoList`/g' \
    -e 's/`TaskGet`/`TodoList`/g' \
    -e 's/`TaskOutput`/`TodoList`/g' \
    -e 's/`TaskStop`/`TodoList`/g' \
    -e 's/TaskCreate/TodoList/g' \
    -e 's/TaskUpdate/TodoList/g' \
    -e 's/TaskList/TodoList/g' \
    -e 's/TaskGet/TodoList/g' \
    -e 's/TaskOutput/TodoList/g' \
    -e 's/TaskStop/TodoList/g' \
    -e 's/`MultiEdit`/`Edit`/g' \
    -e 's/MultiEdit/Edit/g' \
    -e 's/`Task` tool to spawn parallel sub-agents/`Agent` tool to spawn parallel sub-agents/g' \
    -e 's/`Task` tool/`Agent` tool/g' \
    -e 's/Task tool/Agent tool/g' \
    -e 's/\bTask(/Agent(/g' \
    -e 's/`TeamCreate`/team mode (unavailable)/g' \
    -e 's/`SendMessage`/team mode (unavailable)/g' \
    -e 's/TeamCreate/team mode (unavailable)/g' \
    -e 's/SendMessage/team mode (unavailable)/g' \
    -e 's/TeamDelete/team mode (unavailable)/g' \
    -e 's/ToolSearch(query="codesift", max_results=20)/Check if codesift MCP tools are available (mcp__codesift__list_repos)/g' \
    -e 's/ToolSearch(query="codesift"[^)]*)/Check if codesift MCP tools are available/g' \
    -e 's/ToolSearch(query="jcodemunch"[^)]*)/Check if jcodemunch MCP tools are available/g' \
    -e 's/ToolSearch(query="+playwright[^)]*)/Check if playwright MCP tools are available/g' \
    -e 's/`ToolSearch`/MCP tool check/g' \
    -e 's/ToolSearch/MCP tool check/g'
}

# --- Subagent Type Adaptation (Kimi) ---
# Claude Code type -> Kimi builtin profile. Kimi's builtins are: agent, coder,
# explore, plan. `coder` is the ONLY builtin with file-editing tools, so it is the
# right landing spot for general-purpose; read-only exploration goes to `explore`.
adapt_subagent_types() {
  sed \
    -e 's/subagent_type: "general-purpose"/subagent_type: "coder"/g' \
    -e 's/subagent_type="general-purpose"/subagent_type="coder"/g' \
    -e 's/subagent_type=general-purpose/subagent_type=coder/g' \
    -e 's/subagent_type: "Explore"/subagent_type: "explore"/g' \
    -e 's/subagent_type="Explore"/subagent_type="explore"/g' \
    -e 's/subagent_type=Explore/subagent_type=explore/g' \
    -e 's/subagent_type: "Plan"/subagent_type: "plan"/g' \
    -e 's/subagent_type="Plan"/subagent_type="plan"/g' \
    -e 's/type: "general-purpose"/type: "coder"/g' \
    -e 's/type: "Explore"/type: "explore"/g' \
    -e 's/type: "Plan"/type: "plan"/g'
}

# --- Skill prefix for agent naming (kept identical to the Cursor build) ---
get_skill_prefix() {
  local skill="$1"
  case "$skill" in
    dependency-audit) echo "dep-audit" ;;
    write-e2e)       echo "e2e" ;;
    *)               echo "$skill" ;;
  esac
}

# --- Skill Transform for Kimi ---
# Preserves sub-agent dispatch. Only rewrites paths, tool names, subagent types,
# model lanes, and the flat agent-file references.
transform_skill_for_kimi() {
  local src="$1"
  local dst="$2"
  local skill="$3"
  local prefix
  prefix=$(get_skill_prefix "$skill")

  awk '
    BEGIN { in_fm=0; past_fm=0; skip_section=0 }

    # --- Frontmatter: keep name, description, user-invocable ---
    /^---$/ && !in_fm && !past_fm { in_fm=1; in_desc=0; print; next }
    /^---$/ && in_fm { in_fm=0; past_fm=1; in_desc=0; print; next }
    in_fm && /^(name|user-invocable):/ { in_desc=0; print; next }
    in_fm && /^description: "/ { in_desc=1; print; next }
    in_fm && /^description: >/ { in_desc=1; first_desc_line=1; print; next }
    in_fm && /^description:/ { in_desc=1; print; next }
    in_fm && in_desc && first_desc_line && /^[[:space:]]/ { first_desc_line=0; print; next }
    in_fm && in_desc && /^[[:space:]]/ { print; next }
    in_fm && in_desc && !/^[[:space:]]/ { in_desc=0 }
    in_fm { next }

    # --- Skip Path Resolution (Claude-plugin-specific) ---
    /^## Path Resolution/ { skip_section=1; next }
    skip_section && /^## / { skip_section=0 }
    skip_section && /^---$/ { skip_section=0 }
    skip_section { next }

    # --- Default: print (spawn blocks survive — Kimi has real sub-agents) ---
    { print }
  ' "$src" \
    | replace_paths \
    | strip_platform_blocks \
    | adapt_tool_names \
    | adapt_subagent_types \
    | replace_model_refs \
    | replace_reviewer_lane_refs_kimi \
    | sed \
      -e 's/(Sonnet, background)/(primary lane, background)/g' \
      -e 's/(Haiku, background)/(secondary lane, background)/g' \
    | sed \
      -e 's/**Codex \/ Cursor:.*//' \
      -e '/On Cursor, execute each agent.*sequentially/d' \
    | awk '
      # Collapse 3+ consecutive blank lines into 2
      /^$/ { blank++; if (blank <= 2) print; next }
      { blank=0; print }
    ' \
    | normalize_unicode \
    | sed \
      -e "s|skills/dependency-audit/agents/\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/dep-audit-\1.md|g" \
      -e "s|skills/write-e2e/agents/\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/e2e-\1.md|g" \
      -e "s|skills/\([a-z][-a-z]*\)/agents/\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/\1-\2.md|g" \
    | sed \
      -e "s|^\(agents/\)\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/${prefix}-\2.md|g" \
      -e "s|\([^/]\)\(agents/\)\([a-z][-a-z]*\)\.md|\1~/.kimi-code/agents/${prefix}-\3.md|g" \
    > "$dst"

  # Apply in-place config refs (must be after pipe)
  replace_config_refs "$dst"
}

# --- Agent Adaptation for Kimi ---
# Flattens into agents/<prefix>-<name>.md (Kimi resolves agent profiles by a FLAT
# byName map, so subdirectories would silently collide — zuvo ships two pairs of
# same-named agents with different content: cq-auditor and spec-reviewer).
# Frontmatter: name -> prefixed, model: -> model_preference:, tools: KEPT
# (Kimi parses frontmatter["tools"] natively), reasoning: dropped.
adapt_agent_for_kimi() {
  local src="$1"
  local dst="$2"
  local skill="$3"
  local agent_name
  agent_name=$(basename "$src" .md)
  local prefix
  prefix=$(get_skill_prefix "$skill")
  local full_name="${prefix}-${agent_name}"

  awk -v full_name="$full_name" '
    BEGIN { in_fm=0; past_fm=0; skip_section=0 }

    # Frontmatter boundaries
    /^---$/ && !in_fm && !past_fm { in_fm=1; print; next }
    /^---$/ && in_fm { in_fm=0; past_fm=1; print; next }

    # Inside frontmatter
    in_fm && /^name:/ { print "name: " full_name; next }
    in_fm && /^description:/ { print; next }
    in_fm && /^model:/ {
      if ($0 ~ /haiku/ || $0 ~ /review-alt/) {
        print "model_preference: secondary"
      } else {
        print "model_preference: primary"
      }
      next
    }
    in_fm && /^reasoning:/ { next }  # Not a Kimi concept
    in_fm { print; next }

    # Skip "Team Mode Verification" section (Kimi has no multi-session teams)
    /^### .*Team Mode/ { skip_section=1; next }
    skip_section && /^(### |## |---)/ { skip_section=0 }
    skip_section { next }

    # Body: pass through
    { print }
  ' "$src" \
    | replace_paths \
    | strip_platform_blocks \
    | adapt_tool_names \
    | adapt_subagent_types \
    | replace_model_refs \
    | replace_reviewer_lane_refs_kimi \
    | normalize_unicode \
    | sed \
      -e "s|skills/dependency-audit/agents/\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/dep-audit-\1.md|g" \
      -e "s|skills/write-e2e/agents/\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/e2e-\1.md|g" \
      -e "s|skills/\([a-z][-a-z]*\)/agents/\([a-z][-a-z]*\)\.md|~/.kimi-code/agents/\1-\2.md|g" \
    > "$dst"

  replace_config_refs "$dst"
}

# ============================================================
# 1. Normalize rules + shared includes
# ============================================================
echo "Normalizing rules and shared includes..."
mkdir -p "$DIST/rules"

for f in "$PLUGIN_DIR"/rules/*.md; do
  [ -f "$f" ] || continue
  cat "$f" \
    | replace_paths \
    | strip_platform_blocks \
    | adapt_tool_names \
    | adapt_subagent_types \
    | replace_model_refs \
    | replace_reviewer_lane_refs_kimi \
    | normalize_unicode > "$DIST/rules/$(basename "$f")"
  # Config refs for rules: CLAUDE.md -> AGENTS.md but NOT Claude Code -> Kimi Code
  sed_i 's/CLAUDE\.md/AGENTS.md/g' "$DIST/rules/$(basename "$f")"
done
echo "  + rules/ ($(ls "$PLUGIN_DIR"/rules/*.md 2>/dev/null | wc -l | tr -d ' ') files)"

# --- Shared includes ---
if [ -d "$PLUGIN_DIR/shared/includes" ]; then
  mkdir -p "$DIST/shared/includes"
  for f in "$PLUGIN_DIR"/shared/includes/*.md; do
    [ -f "$f" ] || continue
    cat "$f" \
      | replace_paths \
    | strip_platform_blocks \
      | adapt_tool_names \
      | adapt_subagent_types \
      | replace_model_refs \
      | replace_reviewer_lane_refs_kimi \
      | normalize_unicode > "$DIST/shared/includes/$(basename "$f")"
    sed_i 's/CLAUDE\.md/AGENTS.md/g' "$DIST/shared/includes/$(basename "$f")"
  done
  # shell includes (e.g. model-registry.sh) — PLAIN copy, NO transforms: replace_model_refs /
  # reviewer-lane rewrites would turn the registry's claude/codex ids into lanes and corrupt it.
  for f in "$PLUGIN_DIR"/shared/includes/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$DIST/shared/includes/$(basename "$f")"
  done
  echo "  + shared/includes/ ($(ls "$PLUGIN_DIR"/shared/includes/*.md "$PLUGIN_DIR"/shared/includes/*.sh 2>/dev/null | wc -l | tr -d ' ') files)"
fi

# --- Scripts ---
mkdir -p "$DIST/scripts"
for script in adversarial-review.sh benchmark.sh reviewer-model-route.sh blind-audit-codex.sh install-refactor-gate.sh test-coverage-gate.py reviewer-preflight.sh review-artifact-sync.sh; do
  if [ -f "$PLUGIN_DIR/scripts/$script" ]; then
    cp "$PLUGIN_DIR/scripts/$script" "$DIST/scripts/$script"
    chmod +x "$DIST/scripts/$script"
  fi
done
echo "  + scripts/"

# ============================================================
# 2. Hooks
# ============================================================
echo ""
echo "Assembling hooks..."
mkdir -p "$DIST/hooks"

# hooks.kimi.toml — merge template for ~/.kimi-code/config.toml `[[hooks]]` tables
if [ -f "$PLUGIN_DIR/hooks/hooks.kimi.toml" ]; then
  cat "$PLUGIN_DIR/hooks/hooks.kimi.toml" \
    | replace_paths \
    | strip_platform_blocks \
    > "$DIST/hooks.kimi.toml"
  echo "  + hooks.kimi.toml"
fi

# Hook scripts with path replacement.
# refactor-safety-gate.sh is not an event hook — it is the git pre-commit/pre-push gate
# that zuvo:refactor PHASE 0 installs into the repo. Ship it or that phase has nothing
# to install.
for hook_script in block-no-verify.sh route-suite-through-verify.sh pre-push-gate.sh pre-commit-adversarial-gate.sh \
                   post-skill-adversarial-check.sh track-includes.sh zuvo-heartbeat.sh \
                   zuvo-todo-watchdog.sh zuvo-rewake-on-failure.sh zuvo-rewake-reset.sh \
                   zuvo-stop-pipeline-gate.sh zuvo-stop-retro-sweep.sh \
                   skill-usage-logger.sh refactor-safety-gate.sh session-start; do
  if [ -f "$PLUGIN_DIR/hooks/$hook_script" ]; then
    cat "$PLUGIN_DIR/hooks/$hook_script" \
      | replace_paths \
    | strip_platform_blocks \
      > "$DIST/hooks/$hook_script"
    chmod +x "$DIST/hooks/$hook_script"
    echo "  + hooks/$hook_script"
  fi
done

# hooks/lib/ (pre-push + commit gates source pipeline-gate-lib.sh)
if [ -d "$PLUGIN_DIR/hooks/lib" ]; then
  mkdir -p "$DIST/hooks/lib"
  for lib_file in "$PLUGIN_DIR"/hooks/lib/*.sh; do
    [ -f "$lib_file" ] || continue
    cat "$lib_file" | replace_paths > "$DIST/hooks/lib/$(basename "$lib_file")"
    chmod +x "$DIST/hooks/lib/$(basename "$lib_file")"
  done
  echo "  + hooks/lib/ ($(ls "$PLUGIN_DIR"/hooks/lib/*.sh 2>/dev/null | wc -l | tr -d ' ') files)"
fi

# ============================================================
# 3. Assemble skills + flat agents
# ============================================================
echo ""
echo "Assembling skills..."

skill_count=0
agent_count=0
overlay_list=""

for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  skill=$(basename "$skill_dir")
  [ "$skill" = "shared" ] && continue
  prefix=$(get_skill_prefix "$skill")
  mkdir -p "$DIST/skills/$skill"

  # --- SKILL.md: overlay or mechanical transform ---
  if [ -f "$skill_dir/kimi/SKILL.kimi.md" ]; then
    cp "$skill_dir/kimi/SKILL.kimi.md" "$DIST/skills/$skill/SKILL.md"
    overlay_list="$overlay_list $skill"
    echo "  + $skill (overlay)"
  else
    transform_skill_for_kimi "$skill_dir/SKILL.md" "$DIST/skills/$skill/SKILL.md" "$skill"
    echo "  + $skill (auto-transform)"
  fi

  # --- Shared per-skill files ---
  for f in rules.md dimensions.md agent-prompt.md orchestrator-prompt.md; do
    if [ -f "$skill_dir/$f" ]; then
      cat "$skill_dir/$f" \
        | replace_paths \
    | strip_platform_blocks \
        | adapt_tool_names \
        | adapt_subagent_types \
        | replace_model_refs \
        | replace_reviewer_lane_refs_kimi \
        | normalize_unicode > "$DIST/skills/$skill/$f"
      replace_config_refs "$DIST/skills/$skill/$f"
    fi
  done

  # --- Agents -> FLAT agents/ directory with skill prefix ---
  if [ -d "$skill_dir/agents" ]; then
    for agent in "$skill_dir/agents/"*.md; do
      [ -f "$agent" ] || continue
      name=$(basename "$agent" .md)

      # team-lead is NOT a dispatchable agent — the skills that use it say so explicitly
      # ("You do NOT dispatch a sub-agent for this step. Read `agents/team-lead.md` ...
      # then execute it yourself"). Registering it as an agent profile would put a
      # phantom entry in Kimi's subagent_type list; dropping it outright — which is what
      # the Cursor and Antigravity builds do — leaves the skill pointing at a file that
      # was never shipped. So it ships as a plain procedure doc inside the skill dir,
      # and the reference is rewritten to match (see the rewrite pass below).
      if [ "$name" = "team-lead" ]; then
        cat "$agent" \
          | replace_paths \
    | strip_platform_blocks \
          | adapt_tool_names \
          | adapt_subagent_types \
          | replace_model_refs \
          | replace_reviewer_lane_refs_kimi \
          | normalize_unicode > "$DIST/skills/$skill/team-lead.md"
        replace_config_refs "$DIST/skills/$skill/team-lead.md"
        # Repoint the reference the generic agents/*.md rewrite already turned into a
        # flat-namespace path that will never exist.
        sed_i "s|~/\.kimi-code/agents/${prefix}-team-lead\.md|~/.kimi-code/skills/$skill/team-lead.md|g" \
          "$DIST/skills/$skill/SKILL.md"
        sed_i "s|~/\.kimi-code/agents/team-lead\.md|~/.kimi-code/skills/$skill/team-lead.md|g" \
          "$DIST/skills/$skill/SKILL.md"
        echo "    doc: $skill/team-lead.md (inline procedure, not a dispatch target)"
        continue
      fi

      # Skip data-only / redirect files
      is_redirect=$(head -5 "$agent" | grep -ci "REDIRECT\|canonical.*moved" || true)
      has_desc=$(head -20 "$agent" | grep -c "^description:" || true)
      is_data=$(head -5 "$agent" | grep -ci "template\|registry\|column definitions" || true)
      if [ "$is_redirect" -gt 0 ] || [ "$has_desc" -eq 0 ] || [ "$is_data" -gt 0 ]; then
        echo "    skip: $name (data-only)"
        continue
      fi

      adapt_agent_for_kimi "$agent" "$DIST/agents/${prefix}-${name}.md" "$skill"
      echo "    agent: ${prefix}-${name}"
      agent_count=$((agent_count + 1))
    done
  fi

  # --- References ---
  if [ -d "$skill_dir/references" ]; then
    mkdir -p "$DIST/skills/$skill/references"
    for ref in "$skill_dir/references/"*.md; do
      [ -f "$ref" ] || continue
      cat "$ref" \
        | replace_paths \
    | strip_platform_blocks \
        | adapt_tool_names \
        | adapt_subagent_types \
        | replace_model_refs \
        | replace_reviewer_lane_refs_kimi \
        | normalize_unicode > "$DIST/skills/$skill/references/$(basename "$ref")"
      replace_config_refs "$DIST/skills/$skill/references/$(basename "$ref")"
    done
  fi

  skill_count=$((skill_count + 1))
done

# ============================================================
# 4. Validation
# ============================================================
echo ""
echo "Validating..."
errors=0
warnings=0

fail() { echo "  ERROR: $1"; errors=$((errors + 1)); }

# Residual Claude-only tool names. AskUserQuestion / EnterPlanMode / ExitPlanMode are
# DELIBERATELY absent from this list — Kimi has all three.
tool_refs=$(grep -rln 'TodoWrite\|MultiEdit\|TeamCreate\|\bTaskCreate\b' \
  "$DIST"/skills/*/SKILL.md "$DIST"/skills/*/references/*.md "$DIST"/agents/*.md "$DIST"/rules/ 2>/dev/null || true)
if [ -n "$tool_refs" ]; then
  fail "Claude-only tool references found:"
  echo "$tool_refs" | while IFS= read -r f; do echo "    $(echo "$f" | sed "s|$DIST/||")"; done
fi

# Residual {plugin_root}
if grep -rqln '{plugin_root}' "$DIST" 2>/dev/null; then
  fail "Residual {plugin_root} tokens:"
  grep -rln '{plugin_root}' "$DIST" | sed "s|$DIST/|    |"
fi

# Residual platform markers. A leftover marker means some file skipped
# strip_platform_blocks and still carries another harness's instructions — on Kimi that
# means Codex's "single-agent hard rule", i.e. it would talk itself out of its own
# sub-agents.
if grep -rqln '<!-- PLATFORM:' "$DIST" 2>/dev/null; then
  fail "Residual <!-- PLATFORM: --> markers (a file bypassed strip_platform_blocks):"
  grep -rln '<!-- PLATFORM:' "$DIST" | sed "s|$DIST/|    |"
fi

# The Kimi platform section must SURVIVE — it is what tells a run to dispatch rather
# than degrade. Losing it is silent: every skill still runs, just single-agent.
if [ -f "$DIST/shared/includes/env-compat.md" ] \
   && ! grep -q '### Kimi Code' "$DIST/shared/includes/env-compat.md"; then
  fail "env-compat.md lost its Kimi Code section — runs would fall back to inline dispatch"
fi

# Residual ToolSearch
if grep -rqln 'ToolSearch' "$DIST" 2>/dev/null; then
  fail "Residual ToolSearch references:"
  grep -rln 'ToolSearch' "$DIST" | sed "s|$DIST/|    |"
fi

# Residual CLAUDE_PLUGIN_ROOT
if grep -rqln 'CLAUDE_PLUGIN_ROOT' "$DIST" 2>/dev/null; then
  fail "Residual CLAUDE_PLUGIN_ROOT references:"
  grep -rln 'CLAUDE_PLUGIN_ROOT' "$DIST" | sed "s|$DIST/|    |"
fi

# Residual ~/.claude/ paths
claude_paths=$(grep -rln '~/\.claude/' "$DIST"/skills/ "$DIST"/agents/ "$DIST"/shared/ "$DIST"/rules/ 2>/dev/null || true)
if [ -n "$claude_paths" ]; then
  fail "Residual ~/.claude/ paths:"
  echo "$claude_paths" | sed "s|$DIST/|    |"
fi

# Residual Claude model names in agent frontmatter
bad_models=$(grep -rn '^model: \(sonnet\|opus\|haiku\)\|^model: "\(sonnet\|opus\|haiku\)"' \
  "$DIST"/agents/*.md 2>/dev/null || true)
if [ -n "$bad_models" ]; then
  fail "Claude model names in agent frontmatter (should be model_preference):"
  echo "$bad_models" | head -10
fi

# model_preference must be exactly primary|secondary — Kimi hard-fails on anything else
bad_pref=$(grep -rn '^model_preference:' "$DIST"/agents/*.md 2>/dev/null \
  | grep -v '^.*model_preference: *"\?\(primary\|secondary\)"\? *$' || true)
if [ -n "$bad_pref" ]; then
  fail "Invalid model_preference values (must be primary|secondary):"
  echo "$bad_pref" | head -10
fi

# Abstract reviewer lanes must be resolved
lane_refs=$(grep -rn 'review-primary\|review-alt' "$DIST"/skills "$DIST"/agents "$DIST"/shared "$DIST"/rules 2>/dev/null || true)
if [ -n "$lane_refs" ]; then
  fail "Abstract reviewer lanes remain in Kimi dist:"
  echo "$lane_refs" | head -10
fi

# Subagent types must be Kimi builtins or a shipped custom profile
# Agent-type values must be Kimi builtins or a shipped custom profile. zuvo's source
# spells these as `type: "general-purpose"` / `type: "Explore"` inside the dispatch
# pseudo-blocks (22 + 10 occurrences); `subagent_type:` is checked too because the
# adversarial/telemetry includes use that spelling.
# NB: a `case` statement inside $( ) trips bash's parser on the pattern-closing `)`,
# so this deliberately uses a plain if/grep instead.
# `|| true` is load-bearing: this script runs under `set -o pipefail`, where a grep
# that matches nothing (status 1) fails the whole pipeline and set -e kills the build.
check_subagent_types() {
  { grep -rhoE 'subagent_type: *"[a-zA-Z-]+"' "$DIST"/skills/*/SKILL.md 2>/dev/null || true; } \
    | sed 's/.*"\(.*\)"/\1/' | sort -u | while IFS= read -r t; do
      if ! printf '%s\n' "agent coder explore plan" | grep -qw "$t"; then
        [ -f "$DIST/agents/$t.md" ] || echo "$t"
      fi
    done
}
bad_types=$(check_subagent_types)

# Residual CLAUDE agent-type names. Scoped to the three exact spellings zuvo uses —
# a bare `type: "..."` grep would also hit CodeSift query objects
# (`codebase_retrieval(queries=[{type:"semantic"}])`), which are not agent types.
residual_types=$(grep -rn '\(subagent_\)\?type: *"\(general-purpose\|Explore\|Plan\)"' \
  "$DIST"/skills/*/SKILL.md "$DIST"/agents/*.md 2>/dev/null || true)
if [ -n "$residual_types" ]; then
  fail "Claude agent-type names survived (should be coder/explore/plan):"
  echo "$residual_types" | head -10
fi
if [ -n "$bad_types" ]; then
  fail "Unknown subagent_type values (not a Kimi builtin, no matching agent file):"
  echo "$bad_types" | sed 's/^/    /'
fi

# Flat agent namespace: no name collisions, and frontmatter name must match filename
declare_dupes=$(grep -h '^name:' "$DIST"/agents/*.md 2>/dev/null | sort | uniq -d || true)
if [ -n "$declare_dupes" ]; then
  fail "Duplicate agent names in flat namespace (Kimi resolves byName — one would win silently):"
  echo "$declare_dupes" | sed 's/^/    /'
fi

for agent_md in "$DIST"/agents/*.md; do
  [ -f "$agent_md" ] || continue
  base=$(basename "$agent_md" .md)
  fm_name=$(awk '/^name:/{print $2; exit}' "$agent_md")
  if [ "$fm_name" != "$base" ]; then
    fail "Agent name/filename mismatch: $base.md declares name: $fm_name"
  fi
  has_desc=$(head -15 "$agent_md" | grep -c "^description:" || true)
  if [ "$has_desc" -eq 0 ]; then
    echo "  WARN: Agent missing description: $base"
    warnings=$((warnings + 1))
  fi
done

# Sub-agent dispatch must SURVIVE — this build's whole reason to exist. Cursor and
# Antigravity deliberately collapse dispatch to inline-sequential; Kimi must NOT, or its
# audit tiers silently stop being multi-agent while still reporting they ran.
#
# The measured invariant is the count of agent-FILE references, because that is the
# vocabulary zuvo actually uses (54 `agents/<name>.md` refs across 12 of the 15 skills
# that ship agents; `subagent_type` appears zero times in source, and `Task tool` only
# five). Every source reference must survive as a rewritten flat-namespace path — one
# lost reference is one agent the skill can no longer find.
for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  skill=$(basename "$skill_dir")
  [ -d "$skill_dir/agents" ] || continue
  [ -f "$DIST/skills/$skill/SKILL.md" ] || continue
  # An agents/ directory is not proof of agents: using-zuvo's holds only openai.yaml.
  ls "$skill_dir"/agents/*.md >/dev/null 2>&1 || continue

  # Each grep is brace-wrapped with `|| true` — under `set -o pipefail` a no-match grep
  # (status 1) would fail the pipeline and set -e would kill the build mid-validation.
  src_refs=$({ grep -oE 'agents/[a-z][-a-z]*\.md' "$skill_dir/SKILL.md" 2>/dev/null || true; } | sort -u | wc -l | tr -d ' ')
  # Counts BOTH destinations: the flat agent namespace and the skill-local team-lead
  # procedure doc, which is deliberately not an agent profile (see the build step above).
  dst_refs=$({ grep -oE "~/\.kimi-code/agents/[a-z][-a-z]*\.md|~/\.kimi-code/skills/$skill/team-lead\.md" \
    "$DIST/skills/$skill/SKILL.md" 2>/dev/null || true; } | sort -u | wc -l | tr -d ' ')

  if [ "$src_refs" -gt 0 ]; then
    if [ "$dst_refs" -lt "$src_refs" ]; then
      fail "$skill: agent references lost in transform (src=$src_refs unique, dist=$dst_refs)"
    fi
    # Every rewritten reference must point at a file that was actually built, or the
    # skill dispatches into a void at runtime.
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      target="$DIST/agents/$(basename "$ref")"
      [ -f "$target" ] || fail "$skill: references missing agent file $(basename "$ref")"
    done < <({ grep -oE '~/\.kimi-code/agents/[a-z][-a-z]*\.md' "$DIST/skills/$skill/SKILL.md" 2>/dev/null || true; } | sort -u)
  else
    # No file references — fall back to the prose marker every such skill uses.
    dst_disp=$(grep -c 'dispatch\|Agent tool' "$DIST/skills/$skill/SKILL.md" 2>/dev/null || true)
    if [ "$dst_disp" -eq 0 ]; then
      fail "$skill: ships agents/ but dist SKILL.md has no dispatch language left"
    fi
  fi
done

# Shared includes present
include_count=$(ls "$DIST/shared/includes/"*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$include_count" -eq 0 ]; then
  fail "No shared include files found in $DIST/shared/includes/"
fi

# Line count warnings
for f in "$DIST"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  lines=$(wc -l < "$f" | tr -d ' ')
  skill=$(basename "$(dirname "$f")")
  if [ "$lines" -gt 500 ]; then
    echo "  WARN: $skill/SKILL.md exceeds 500 lines ($lines)"
    warnings=$((warnings + 1))
  fi
done

# Hook template validation — must parse as TOML and use Kimi's flat [[hooks]] shape
if [ -f "$DIST/hooks.kimi.toml" ]; then
  # zuvo_python PRINTS an interpreter path, it does not run one — calling it directly
  # would swallow the heredoc and silently pass.
  KIMI_PY="$(zuvo_python 2>/dev/null || true)"
  # UNQUOTED on purpose, and split into an array: scripts/lib/portable.sh documents that
  # zuvo_python can return the TWO-WORD string "py -3" on Windows, where no bare python3/python
  # exists. Quoted as one token, bash would exec a file literally named `py -3`, fail, and report
  # "hooks.kimi.toml failed schema validation" on perfectly valid TOML — blocking the whole Kimi
  # target on the one platform zuvo_python exists to support. runlog-sync.sh:14 leaves $PY_BIN
  # unquoted for exactly this reason.
  read -r -a KIMI_PY_ARGV <<< "$KIMI_PY"
  if [ "${#KIMI_PY_ARGV[@]}" -eq 0 ]; then
    echo "  WARN: no python3 — hooks.kimi.toml schema not validated"
    warnings=$((warnings + 1))
  elif ! "${KIMI_PY_ARGV[@]}" - "$DIST/hooks.kimi.toml" <<'PYEOF'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)  # py<3.11: skip, install-time merge validates again
VALID_EVENTS = {
    "PreToolUse","PostToolUse","PostToolUseFailure","PermissionRequest","PermissionResult",
    "UserPromptSubmit","UserPromptQueued","TurnStarted","Stop","StopFailure","Interrupt",
    "SessionStart","SessionEnd","SessionHeartbeat","SubagentStart","SubagentStop",
    "TaskStarted","PreCompact","PostCompact","Notification",
}
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
hooks = data.get("hooks")
if not isinstance(hooks, list) or not hooks:
    print("hooks.kimi.toml: [[hooks]] must be a non-empty array of tables"); sys.exit(1)
allowed = {"event", "matcher", "command", "timeout"}
for h in hooks:
    extra = set(h) - allowed
    if extra:
        print(f"hooks.kimi.toml: unknown key(s) {sorted(extra)} — schema is .strict()"); sys.exit(1)
    if h.get("event") not in VALID_EVENTS:
        print(f"hooks.kimi.toml: invalid event {h.get('event')!r}"); sys.exit(1)
    if not h.get("command"):
        print("hooks.kimi.toml: command is required"); sys.exit(1)
    t = h.get("timeout")
    if t is not None and not (isinstance(t, int) and 1 <= t <= 600):
        print(f"hooks.kimi.toml: timeout {t!r} out of range 1..600"); sys.exit(1)
PYEOF
  then
    fail "hooks.kimi.toml failed schema validation"
  fi
  if grep -q 'CLAUDE_PLUGIN_ROOT\|\.claude/' "$DIST/hooks.kimi.toml" 2>/dev/null; then
    fail "hooks.kimi.toml contains Claude paths (path leak)"
  fi
else
  echo "  WARN: hooks.kimi.toml not found in dist"
  warnings=$((warnings + 1))
fi

if [ ! -x "$DIST/hooks/pre-push-gate.sh" ]; then
  echo "  WARN: hooks/pre-push-gate.sh missing or not executable"
  warnings=$((warnings + 1))
fi
if [ ! -f "$DIST/hooks/session-start" ]; then
  echo "  WARN: hooks/session-start missing"
  warnings=$((warnings + 1))
fi

# ============================================================
# Summary
# ============================================================
echo ""
if [ "$errors" -gt 0 ]; then
  echo "BUILD FAILED: $errors error(s)"
  exit 1
fi

echo "Build complete: $DIST"
echo "  Skills: $skill_count"
echo "  Agents: $agent_count (flat in agents/)"
echo "  Shared includes: $include_count"
if [ -n "$overlay_list" ]; then
  echo "  Overlays:$overlay_list"
fi
if [ "$warnings" -gt 0 ]; then
  echo "  Warnings: $warnings"
fi
