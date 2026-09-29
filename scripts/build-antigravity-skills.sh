#!/bin/bash
# Build Antigravity-adapted skills from zuvo-plugin source skills.
# Antigravity uses native agent subdirectories (no flat renaming),
# Gemini model mapping. Skills install to ~/.gemini/config/skills (Antigravity's GLOBAL
# CUSTOMIZATION ROOT -- proven by A/B canary 2026-08-11); shared/rules/scripts stay under
# ~/.gemini/antigravity/ and are referenced by absolute path, which works from anywhere.
#
# Template: build-cursor-skills.sh (simplified — no TOML, no flat agents)
#
# Usage: bash scripts/build-antigravity-skills.sh [plugin-dir]

set -euo pipefail

PLUGIN_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# DIST root is env-overridable (B-DIST-BUILD-RACE). Every builder wrote to $PLUGIN_DIR/dist/<p>,
# and reviewer-model-builds.bats `rm -rf`s that tree in its per-test setup() — so one test file
# could truncate a directory another was asserting against. It went red about twice in ten suite
# runs and produced TWO wrong conclusions in one session: a bisect that blamed an innocent registry
# change, and a "regression" that was not one. Both were only caught by re-running in a git
# worktree with its own dist/. Unset, this is exactly the previous path, so install.sh is unchanged.
DIST="${ZUVO_DIST_ROOT:-$PLUGIN_DIR/dist}/antigravity"

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"
# The reviewer-LANE grammar (plan C Task 4) — used by (a) the leftover-lane scan in Validation and
# (b) zrl_agent_model_known (fix round 2, G1: moved here from a byte-identical per-build copy —
# CQ14/CQ20 in the round-1 quality review), the STRICT reader's own grammar (zrl_frontmatter_model)
# read ahead of adapt_agent_for_antigravity's awk, so an agent with no readable `model:` or a value
# this build cannot map fails the build BY NAME instead of silently becoming `gemini-3.1-pro-low`
# (fix round 1, C1 — the same defect class Task 3 closed in build-codex-skills.sh's map_model).
# `review-primary` / `review-alt` are the router's lane NAMES, and prose
# (shared/includes/test-reviewer-routing.md, env-compat.md, session-state.md, execute/retro)
# quotes them to say what to do with the router's answer; this build used to rewrite them
# dist-wide, so every installed copy of those docs disagreed with the router it documents —
# sourcing this library is what lets the leftover scan reuse ITS lenient grammar instead of a sixth
# copy of the same regex.
# Guarded the way build-codex-skills.sh guards its MODEL_REGISTRY source: a clear, build-specific
# error before anything is read, plus (stronger than Codex's guard) a check that sourcing actually
# defined what this build calls — a truncated or renamed library fails loudly here, not with a
# confusing "command not found" mid-build.
LANES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/reviewer-lanes.sh"
if [ ! -f "$LANES_LIB" ]; then
  echo "ERROR: reviewer-lanes.sh not found: $LANES_LIB — the Antigravity build cannot validate reviewer lanes without it" >&2
  exit 1
fi
. "$LANES_LIB"
# zrl_require_functions is itself part of what a broken library may lack, so check it first.
if ! declare -F zrl_require_functions >/dev/null 2>&1; then
  echo "ERROR: zrl_require_functions is not defined after sourcing $LANES_LIB — the library is missing or incomplete" >&2
  exit 1
fi
zrl_require_functions "$LANES_LIB" zrl_read_agent_model zrl_check_agent_model zrl_frontmatter_model \
  zrl_agent_model_known zrl_scan_md zrl_count_refs zrl_show_refs || exit 1


echo "Building Antigravity skills..."
echo "  Source: $PLUGIN_DIR"
echo "  Output: $DIST"
echo ""

# Clean previous build
rm -rf "$DIST"
mkdir -p "$DIST/skills"

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

# --- Platform-block stripping (Antigravity) ---
# Drop every OTHER platform's block and unwrap our own. This build had no such stage at all
# until 2026-08-16, so every Antigravity install shipped shared/includes/env-compat.md with
# Codex's "single-agent hard rule", Cursor's sequential-execution note and (once Kimi landed)
# Kimi's dispatch prose all present verbatim — and an agent that reads Codex's hard rule
# degrades ITSELF to single-agent although Antigravity has full dispatch. Silent by
# construction: every skill still runs, just weaker. The three sibling builders each carried
# their own copy of this, which is exactly why the fourth could be forgotten (see B-19).
strip_platform_blocks() {
  sed \
    -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
    -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
    -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
    -e '/<!-- PLATFORM:ANTIGRAVITY -->/d' \
    -e '/<!-- \/PLATFORM:ANTIGRAVITY -->/d'
}


# --- Path Replacement (Antigravity) ---
# CRITICAL: Replace ALL relative paths (../../) with absolute ~/.gemini/antigravity/ paths.
# Relative paths work in Claude Code (plugin resolves from SKILL.md location) but NOT in
# Antigravity/Codex/Cursor where the agent reads instructions and resolves from CWD.
replace_paths() {
  sed \
    -e 's|{plugin_root}/shared/|~/.gemini/antigravity/shared/|g' \
    -e 's|{plugin_root}/rules/|~/.gemini/antigravity/rules/|g' \
    -e 's|{plugin_root}/skills/|~/.gemini/config/skills/|g' \
    -e 's|{plugin_root}|~/.gemini/antigravity|g' \
    -e 's|CLAUDE_PLUGIN_ROOT|GEMINI_HOME|g' \
    -e 's|~/\.claude/plugins/cache/zuvo-marketplace/zuvo/[^/]*/scripts/adversarial-review\.sh|~/.gemini/antigravity/scripts/adversarial-review.sh|g' \
    -e 's|~/\.claude/plugins/cache/zuvo-marketplace/zuvo/[^/]*/|~/.gemini/antigravity/|g' \
    -e 's|\$HOME/\.claude/|$HOME/.gemini/antigravity/|g' \
    -e 's|~/\.claude/|~/.gemini/antigravity/|g' \
    -e 's|../../shared/includes/|~/.gemini/antigravity/shared/includes/|g' \
    -e 's|../../shared/|~/.gemini/antigravity/shared/|g' \
    -e 's|../../scripts/|~/.gemini/antigravity/scripts/|g' \
    -e 's|../../rules/|~/.gemini/antigravity/rules/|g' \
    -e 's|../../skills/|~/.gemini/config/skills/|g'
}

# --- Model Replacement (Antigravity — Gemini tiers) ---
# The `review-primary`/`review-alt` lines that used to live here are GONE (fix round 1, C3): this
# runs over rules/ and shared/includes/ too, un-anchored, so it matched the literal text
# `model: review-primary` wherever it appeared, not only inside an agent's own frontmatter —
# exactly the prose-corruption class plan C Task 4 exists to close, and it masked a planted rules/
# frontmatter lane from the leftover scan below (found while proving C3's RED case actually reds).
# Agent frontmatter no longer needs it either: adapt_agent_for_antigravity's own `model:` branch
# now only ever runs on a value agent_model_known_antigravity already accepted (fix round 1, C1),
# so it always resolves the lane itself — this function ran on its OUTPUT, after the lane was
# already gone. haiku/sonnet/opus stay: those are tier synonyms, not router lane names, and are
# not part of what plan C Task 3/4 preserve in prose.
replace_model_refs() {
  sed \
    -e 's/model: sonnet/model: gemini-3.1-pro-low/g' \
    -e 's/model: opus/model: gemini-3.1-pro-high/g' \
    -e 's/model: haiku/model: gemini-3-flash/g' \
    -e 's/model: "sonnet"/model: "gemini-3.1-pro-low"/g' \
    -e 's/model: "opus"/model: "gemini-3.1-pro-high"/g' \
    -e 's/model: "haiku"/model: "gemini-3-flash"/g' \
    -e 's/Model | Sonnet/Model | Gemini 3.1 Pro Low/g' \
    -e 's/Model | Opus/Model | Gemini 3.1 Pro High/g' \
    -e 's/Model | Haiku/Model | Gemini 3 Flash/g' \
    -e 's/| Sonnet |/| Gemini 3.1 Pro Low |/g' \
    -e 's/| Opus |/| Gemini 3.1 Pro High |/g' \
    -e 's/| Haiku |/| Gemini 3 Flash |/g' \
    -e 's/-> Sonnet/-> Gemini 3.1 Pro Low/g' \
    -e 's/-> Opus/-> Gemini 3.1 Pro High/g' \
    -e 's/-> Haiku/-> Gemini 3 Flash/g'
}

# --- Config Reference Replacement (Antigravity) ---
# CRITICAL: Claude Code -> Antigravity ONLY in skill body text, NOT shared includes
replace_config_refs() {
  local file="$1"
  # Always safe: config file name
  sed_i 's/CLAUDE\.md/GEMINI.md/g' "$file"
  # Platform name — only in skills, NOT shared includes
  if [[ "$file" == *"/skills/"* ]] && [[ "$file" != *"/shared/"* ]]; then
    sed_i 's/Claude Code/Antigravity/g' "$file"
  fi
}

# --- Strip Claude Code Tool Names ---
strip_tool_names() {
  sed \
    -e 's/`EnterPlanMode`/plan mode/g' \
    -e 's/`ExitPlanMode`/exit plan mode/g' \
    -e 's/`AskUserQuestion`/\[AUTO-DECISION: proceed with safest default\]/g' \
    -e 's/EnterPlanMode/enter plan mode/g' \
    -e 's/ExitPlanMode/finalize the plan/g' \
    -e 's/AskUserQuestion/\[AUTO-DECISION: proceed with safest default\]/g' \
    -e 's/`TaskCreate`/inline progress/g' \
    -e 's/`TaskUpdate`/task update/g' \
    -e 's/`TaskList`/task list/g' \
    -e 's/`TaskOutput`/task output/g' \
    -e 's/`TaskStop`/task stop/g' \
    -e 's/`TaskGet`/task status/g' \
    -e 's/TaskCreate/inline progress/g' \
    -e 's/TaskUpdate/task update/g' \
    -e 's/TaskOutput/task output/g' \
    -e 's/TaskStop/task stop/g' \
    -e 's/TaskGet/task status/g' \
    -e 's/TaskList/task list/g' \
    -e 's/TeamCreate/create team/g' \
    -e 's/SendMessage/send message/g' \
    -e 's/TeamDelete/delete team/g' \
    -e 's/shutdown_request/shutdown request/g' \
    -e 's/ToolSearch(query="codesift", max_results=20)/Check if codesift MCP tools are available (mcp__codesift__list_repos)/g' \
    -e 's/ToolSearch(query="codesift"[^)]*)/Check if codesift MCP tools are available/g' \
    -e 's/ToolSearch(query="jcodemunch"[^)]*)/Check if jcodemunch MCP tools are available/g' \
    -e 's/ToolSearch(query="+playwright[^)]*)/Check if playwright MCP tools are available/g' \
    -e 's/`ToolSearch`/MCP tool check/g' \
    -e 's/ToolSearch/MCP tool check/g'
}

# --- Skill prefix for agent naming ---
get_skill_prefix() {
  local skill="$1"
  case "$skill" in
    dependency-audit) echo "dep-audit" ;;
    write-e2e)       echo "e2e" ;;
    *)               echo "$skill" ;;
  esac
}


# --- Skill Transform for Antigravity ---
# Similar to Cursor but: keeps agent subdirectories (no flat renaming),
# maps models to Gemini tiers (not inherit/fast), no readonly field.
transform_skill_for_antigravity() {
  local src="$1"
  local dst="$2"
  local skill="$3"
  local prefix
  prefix=$(get_skill_prefix "$skill")

  awk -v prefix="$prefix" '
    BEGIN { in_fm=0; past_fm=0; skip_section=0; in_code=0; in_spawn=0; agent="" }

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

    # --- Skip sections: Progress Tracking, Path Resolution ---
    /^## Progress Tracking/ { skip_section=1; next }
    /^## Path Resolution/ { skip_section=1; next }
    skip_section && /^## / { skip_section=0 }
    skip_section && /^---$/ { skip_section=0 }
    skip_section { next }

    # --- Spawn block replacement ---
    /^[[:space:]]*```/ && !in_code {
      in_code=1
      saved_fence=$0
      next
    }

    # First line inside code block -- decide if spawn or normal
    in_code && !in_spawn && saved_fence != "" {
      if ($0 ~ /Spawn via Task tool/) {
        in_spawn=1
        agent=""
        saved_fence=""
        next
      } else if ($0 ~ /^[[:space:]]*Task\(/) {
        in_spawn=1
        agent=""
        saved_fence=""
        next
      } else {
        print saved_fence
        saved_fence=""
        print
        next
      }
    }

    # Inside spawn block: capture agent name, skip content
    in_spawn && /agents\/[a-z][-a-z]*\.md/ {
      s=$0
      gsub(/.*agents\//, "", s)
      gsub(/\.md.*/, "", s)
      agent=s
      next
    }
    in_spawn && /^[[:space:]]*```/ {
      # End of spawn block -- emit inline sequential instruction
      if (agent != "") {
        print "Execute inline: read instructions from `agents/" agent ".md` and perform the analysis yourself."
      } else {
        print "Perform this analysis yourself."
      }
      print ""
      in_code=0
      in_spawn=0
      agent=""
      next
    }
    in_spawn { next }

    # Normal code block closing fence
    /^[[:space:]]*```/ && in_code { in_code=0; print; next }

    # --- Remove tool metadata lines (outside code blocks) ---
    /^[[:space:]]*subagent_type:/ { next }
    /^[[:space:]]*run_in_background:/ { next }

    # --- Remove table rows/headers with subagent_type column ---
    /\| *subagent_type *\|/ { next }

    # --- Remove Claude Code-specific paragraphs ---
    /^The Task tool does NOT read/ { next }
    /^.*MUST specify the `model` parameter explicitly on every Task call/ { next }

    # --- Default: print ---
    { print }
  ' "$src" \
    | replace_paths \
    | strip_platform_blocks \
    | strip_tool_names \
    | replace_model_refs \
    | sed \
      -e 's/`subagent_type: "general-purpose"`//g' \
      -e 's/subagent_type: "general-purpose"//g' \
      -e 's/subagent_type: "Explore"//g' \
      -e 's/subagent_type=Explore//g' \
      -e 's/subagent_type=general-purpose//g' \
      -e 's/run_in_background=true//g' \
      -e 's/run_in_background: true//g' \
      -e 's/`Task` tool to spawn parallel sub-agents/sequential inline execution/g' \
      -e 's/`Task` tool/inline execution/g' \
      -e 's/Task tool/inline execution/g' \
      -e 's/`Agent` tool/inline execution/g' \
      -e 's/Agent tool/inline execution/g' \
      -e 's/(Sonnet, background)/(/g' \
      -e 's/(Haiku, background)/(/g' \
      -e 's/(parallel, background)/(sequential)/g' \
    | sed \
      -e 's/**Codex \/ Cursor:.*//' \
      -e '/On Cursor, execute each agent.*sequentially/d' \
      -e 's/\. Claude Code may parallelize.*$/\./' \
      -e 's/\*\*Claude Code only\*\* (has.*)//' \
    | awk '
      # Collapse 3+ consecutive blank lines into 2
      /^$/ { blank++; if (blank <= 2) print; next }
      { blank=0; print }
    ' \
    | normalize_unicode \
    > "$dst"

  # Apply in-place config refs (must be after pipe)
  replace_config_refs "$dst"
}

# --- Agent Adaptation for Antigravity ---
# Keeps subdirectory structure (no flat renaming).
# Maps model to Gemini tiers, drops tools: list.
adapt_agent_for_antigravity() {
  local src="$1"
  local dst="$2"

  zrl_strip_bom_crlf < "$src" | awk '
    BEGIN { in_fm=0; past_fm=0; skip_tools=0 }

    # Frontmatter boundaries. The input is pre-normalized to LF-only, BOM-free (fix round 3, A3 --
    # replaces round 2 CR-tolerant regexes, which only handled CRLF and never handled a BOM at
    # all): without that normalization, a BOM or CRLF file could pass the C1 gate (which reads its
    # model: value through zrl_frontmatter_model, which DOES tolerate both) and then fall through
    # here unconverted, because /^---$/ would never match a BOM-or-CR-prefixed line and in_fm would
    # never be set -- the whole frontmatter, model: line included, copied through as plain body
    # text instead of being adapted.
    /^---$/ && !in_fm && !past_fm { in_fm=1; print; next }
    /^---$/ && in_fm {
      in_fm=0; past_fm=1; skip_tools=0
      print "---"
      next
    }

    # Inside frontmatter
    in_fm && /^name:/ { print; next }
    in_fm && /^description:/ { print; next }
    in_fm && /^model:/ {
      if ($0 ~ /haiku/) {
        print "model: gemini-3-flash"
      } else if ($0 ~ /review-primary/) {
        print "model: gemini-3.1-pro-high"
      } else if ($0 ~ /review-alt/) {
        print "model: gemini-3.1-pro-low"
      } else if ($0 ~ /per-task/) {
        # EXPLICIT, checked before the /opus/ branch below (fix round 3, A7): the real per-task
        # value is "per-task: sonnet for standard complexity, opus for complex", and matching
        # /opus/ against the WHOLE line found "opus for complex" by substring accident, resolving
        # every per-task agent to the high tier regardless of what the descriptor actually says.
        # gemini-3.1-pro-low is the SAME choice build-codex-skills.sh map_model makes for per-task
        # (its per-task/per-task: case maps to gpt-5.4, the default/lower tier) -- matching Codex
        # keeps the per-task resolution consistent across targets rather than inventing a second
        # policy here.
        print "model: gemini-3.1-pro-low"
      } else if ($0 ~ /opus/) {
        print "model: gemini-3.1-pro-high"
      } else {
        print "model: gemini-3.1-pro-low"
      }
      next
    }
    in_fm && /^reasoning:/ { next }  # Drop
    in_fm && /^tools:/ { skip_tools=1; next }
    in_fm && skip_tools && /^  - / { next }
    in_fm && skip_tools && !/^  - / { skip_tools=0 }
    in_fm { print; next }

    # Body: pass through
    { print }
  ' \
    | replace_paths \
    | strip_platform_blocks \
    | strip_tool_names \
    | replace_model_refs \
    | normalize_unicode > "$dst"

  # Apply in-place config refs
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
    | strip_tool_names \
    | replace_model_refs \
    | normalize_unicode > "$DIST/rules/$(basename "$f")"
  # Config refs for rules: CLAUDE.md -> GEMINI.md but NOT Claude Code -> Antigravity
  sed_i 's/CLAUDE\.md/GEMINI.md/g' "$DIST/rules/$(basename "$f")"
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
      | strip_tool_names \
      | replace_model_refs \
      | normalize_unicode > "$DIST/shared/includes/$(basename "$f")"
    # Config refs for shared: CLAUDE.md -> GEMINI.md but NOT Claude Code -> Antigravity
    sed_i 's/CLAUDE\.md/GEMINI.md/g' "$DIST/shared/includes/$(basename "$f")"
  done
  # shell includes (e.g. model-registry.sh) — PLAIN copy, NO transforms: replace_model_refs /
  # reviewer-lane rewrites would turn the registry's claude/codex ids into gemini and corrupt it.
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
# The shared script libraries — EVERY regular file of scripts/lib/, model-subprocess.sh required, the
# dir regenerated — beside the adversarial-review.sh above: zuvo_ship_runner_lib (scripts/lib/portable.sh)
# says why each of those holds. install_antigravity ships this dir through install_runner_lib.
zuvo_ship_runner_lib "$PLUGIN_DIR" "$DIST" "Antigravity build's" || exit 1
echo "  + scripts/"

# --- Hooks ---
echo ""
echo "Assembling hooks..."
mkdir -p "$DIST/hooks"

# Copy hooks.antigravity.json as hooks.json (merge template for settings.json)
if [ -f "$PLUGIN_DIR/hooks/hooks.antigravity.json" ]; then
  cat "$PLUGIN_DIR/hooks/hooks.antigravity.json" \
    | replace_paths \
    > "$DIST/hooks.json"
  echo "  + hooks.json (from hooks.antigravity.json)"
fi

# Copy hook scripts with path replacement
# block-no-verify.sh added (Antigravity BeforeTool/run_shell_command). The Stop
# nudge is NOT shipped — Antigravity has no Stop hook; pre-push + CI cover it.
# refactor-safety-gate.sh is not an event hook — it is the git pre-commit/pre-push gate that
# zuvo:refactor PHASE 0 installs into the repo. Ship it or that phase has nothing to install.
for hook_script in block-no-verify.sh route-suite-through-verify.sh require-inventory-first.sh pre-push-gate.sh pre-commit-adversarial-gate.sh refactor-safety-gate.sh session-start; do
  if [ -f "$PLUGIN_DIR/hooks/$hook_script" ]; then
    cat "$PLUGIN_DIR/hooks/$hook_script" \
      | replace_paths \
      > "$DIST/hooks/$hook_script"
    chmod +x "$DIST/hooks/$hook_script"
    echo "  + hooks/$hook_script"
  fi
done

# Copy hooks/lib/ recursively (pre-push + commit gates source pipeline-gate-lib.sh)
if [ -d "$PLUGIN_DIR/hooks/lib" ]; then
  mkdir -p "$DIST/hooks/lib"
  for lib_file in "$PLUGIN_DIR"/hooks/lib/*.sh "$PLUGIN_DIR"/hooks/lib/*.py; do
    [ -f "$lib_file" ] || continue
    cat "$lib_file" | replace_paths > "$DIST/hooks/lib/$(basename "$lib_file")"
    chmod +x "$DIST/hooks/lib/$(basename "$lib_file")"
    echo "  + hooks/lib/$(basename "$lib_file")"
  done
fi

# ============================================================
# 2. Assemble skills + agents (in subdirectories)
# ============================================================
echo ""
echo "Assembling skills..."

skill_count=0
agent_count=0
overlay_list=""
# Hoisted above Validation (plan C Task 4 fix round 1, C1): the per-agent model check below runs
# DURING assembly, one agent before Validation's block even starts, so the counters it increments
# must already exist. Validation no longer re-zeroes them — see the comment there.
errors=0
warnings=0

for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  # Strip the trailing slash the glob itself puts on skill_dir (fix round 3, A12): every
  # "$skill_dir/..." reference below inserts its OWN "/" separator, so leaving the glob's slash in
  # place doubled it -- every source path this build named in an error message (an agent, a
  # skipped file) read as .../skills/<skill>//agents/<file>.md.
  skill_dir="${skill_dir%/}"
  skill=$(basename "$skill_dir")
  [ "$skill" = "shared" ] && continue
  mkdir -p "$DIST/skills/$skill"

  # --- SKILL.md: overlay or mechanical transform ---
  if [ -f "$skill_dir/antigravity/SKILL.antigravity.md" ]; then
    cp "$skill_dir/antigravity/SKILL.antigravity.md" "$DIST/skills/$skill/SKILL.md"
    overlay_list="$overlay_list $skill"
    echo "  + $skill (overlay)"
  else
    transform_skill_for_antigravity "$skill_dir/SKILL.md" "$DIST/skills/$skill/SKILL.md" "$skill"
    echo "  + $skill (auto-transform)"
  fi

  # --- Shared files (rules.md, dimensions.md, agent-prompt.md, orchestrator-prompt.md) ---
  for f in rules.md dimensions.md agent-prompt.md orchestrator-prompt.md; do
    if [ -f "$skill_dir/$f" ]; then
      cat "$skill_dir/$f" \
        | replace_paths \
        | strip_platform_blocks \
        | strip_tool_names \
        | replace_model_refs \
        | normalize_unicode > "$DIST/skills/$skill/$f"
      replace_config_refs "$DIST/skills/$skill/$f"
    fi
  done

  # --- Agents -> keep in subdirectories (NOT flat) ---
  if [ -d "$skill_dir/agents" ]; then
    mkdir -p "$DIST/skills/$skill/agents"
    for agent in "$skill_dir/agents/"*.md; do
      [ -f "$agent" ] || continue
      name=$(basename "$agent" .md)

      # Skip team-lead agents
      if [ "$name" = "team-lead" ]; then
        echo "    skip: $name (team-lead)"
        continue
      fi

      # The model, through the STRICT READER (lib/reviewer-lanes.sh, zrl_read_agent_model): read
      # ONCE, ahead of the data-only skip below, and used for both (fix round 3, A1: a file whose
      # leading frontmatter has a READABLE model: is an AGENT, never data-only, regardless of what its
      # description says — skills/content-expand/agents/prose-quality-scorer.md is the case that
      # was silently dropped before). Status 3 = no temp file; it skips the data-only heuristic too.
      agent_model_rc=0
      agent_model_value=$(zrl_read_agent_model "$agent") || agent_model_rc=$?

      # Skip data-only / redirect files -- only when there is NO readable model: (fix round 3, A1)
      # and the file is actually readable (fix round 2, G2): head/grep both return empty on a
      # permission error, which used to misclassify an unreadable agent as "data-only" and skip it
      # silently, before the model check below ever saw it. An unreadable file falls through to
      # that check instead, which reports it by name. root reads everything, so this gate is a
      # no-op when the build runs as root (fix round 3: no fix needed here — the G2 tests already
      # skip themselves under root, since chmod 000 cannot lock root out either).
      if [ "$agent_model_rc" -ne 0 ] && [ "$agent_model_rc" -ne 3 ] && [ -r "$agent" ]; then
        is_redirect=$(head -5 "$agent" | grep -ci "REDIRECT\|canonical.*moved" || true)
        has_desc=$(head -20 "$agent" | grep -c "^description:" || true)
        is_data=$(head -5 "$agent" | grep -ci "template\|registry\|column definitions" || true)
        if [ "$is_redirect" -gt 0 ] || [ "$has_desc" -eq 0 ] || [ "$is_data" -gt 0 ]; then
          echo "    skip: $name (data-only)"
          continue
        fi
      fi

      # Every read status gets its own message, and an unknown model value is named
      # (zrl_check_agent_model — one wording for the Cursor, Antigravity and Kimi builds).
      if ! zrl_check_agent_model Antigravity "$agent" "$agent_model_rc" "${agent_model_value:-}"; then
        errors=$((errors + 1))
        continue
      fi

      adapt_agent_for_antigravity "$agent" "$DIST/skills/$skill/agents/$name.md"
      echo "    agent: $skill/$name"
      agent_count=$((agent_count + 1))
    done
  fi

  # --- References ---
  if [ -d "$skill_dir/references" ]; then
    mkdir -p "$DIST/skills/$skill/references"
    for ref in "$skill_dir/references/"*.md; do
      [ -f "$ref" ] || continue
      cat "$ref" | replace_paths | strip_platform_blocks | replace_model_refs | normalize_unicode > "$DIST/skills/$skill/references/$(basename "$ref")"
      replace_config_refs "$DIST/skills/$skill/references/$(basename "$ref")"
    done
  fi

  skill_count=$((skill_count + 1))
done

# ============================================================
# 3. Validation
# ============================================================
echo ""
echo "Validating..."
# errors/warnings are declared above the assembly loop (plan C Task 4 fix round 1, C1) — the
# per-agent model check already counted into them before this section starts; re-zeroing here
# would silently discard those.

# Check for Claude Code-specific tool references
# references/*.md is IN SCOPE: it is copied verbatim into the dist above, so
# without it a Claude-only tool name just has to move out of SKILL.md to ship.
tool_refs=$(grep -rln \
  'EnterPlanMode\|ExitPlanMode\|AskUserQuestion\|TeamCreate\|SendMessage' \
  "$DIST"/skills/*/SKILL.md "$DIST"/skills/*/references/*.md "$DIST"/rules/ 2>/dev/null || true)

if [ -n "$tool_refs" ]; then
  echo "  ERROR: Claude Code tool references found:"
  echo "$tool_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
    grep -n 'EnterPlanMode\|ExitPlanMode\|AskUserQuestion\|TeamCreate\|SendMessage' "$f" | head -3 | while IFS= read -r line; do
      echo "      $line"
    done
  done
  errors=$((errors + 1))
fi

# Check for residual {plugin_root} tokens
plugin_root_refs=$(grep -rln '{plugin_root}' "$DIST" 2>/dev/null || true)
if [ -n "$plugin_root_refs" ]; then
  echo "  ERROR: Residual {plugin_root} tokens found:"
  echo "$plugin_root_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Check for residual ToolSearch
toolsearch_refs=$(grep -rln 'ToolSearch' "$DIST" 2>/dev/null || true)
if [ -n "$toolsearch_refs" ]; then
  echo "  ERROR: Residual ToolSearch references found:"
  echo "$toolsearch_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Check for residual CLAUDE_PLUGIN_ROOT
cpr_refs=$(grep -rln 'CLAUDE_PLUGIN_ROOT' "$DIST" 2>/dev/null || true)
if [ -n "$cpr_refs" ]; then
  echo "  ERROR: Residual CLAUDE_PLUGIN_ROOT references found:"
  echo "$cpr_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Check for residual Claude model names in agent frontmatter
bad_models=$(grep -rn 'model: sonnet\|model: opus\|model: haiku\|model: "sonnet"\|model: "opus"\|model: "haiku"' \
  "$DIST"/skills/*/agents/*.md "$DIST"/skills/*/SKILL.md 2>/dev/null || true)
if [ -n "$bad_models" ]; then
  echo "  ERROR: Claude model names found (should be Gemini):"
  echo "$bad_models" | head -10
  errors=$((errors + 1))
fi

# Abstract reviewer lanes must be resolved IN AGENT FRONTMATTER (plan C Task 4). This is the
# shared lenient scan (scripts/lib/reviewer-lanes.sh) restricted to a `model:` key inside a
# file's own leading frontmatter block, so it catches a lane adapt_agent_for_antigravity's awk
# failed to recognize (BOM, indentation, a quoted key, CRLF, any case, flow/comma syntax, …)
# without flagging the same words when prose quotes the router's lane names. EVERY tree this
# build writes a `.md` into is scanned (fix round 1, C4: checked — unlike Cursor/Kimi, this build
# never flattens agents into a top-level agents/ dir, they stay under skills/<skill>/agents/, so
# skills/ + shared/ + rules/ is already every `.md` tree; fix round 2, E3: references/*.md nests
# under skills/<skill>/references/, already inside $DIST/skills — a planted references/ fixture
# was verified caught by this same list before E3 changed anything, so no path was added for it.
# hooks.json and the scripts/hooks copies are not markdown). A tree missing from this list would
# be a build error, not a skip — `_zrl_paths_exist` inside zrl_scan_md fails the scan closed on a
# missing path, caught by the `else` branch below, never silently treated as "no lanes found". The
# scan fails CLOSED on a value it cannot parse at all (a YAML block scalar, an unclosed quote) —
# the old whole-file substring gate silently let such a file through; this is intended (plan C
# Task 3 design), and it is proven harmless below (fix round 1, C7): all 48 real agents build with
# zero leftover.
# zrl_scan_and_report_lanes (fix round 3, A4/W12) runs the capture in its OWN subshell with its
# own trap — this script's exit path is never touched by it — and returns the error count; it must
# not run as a bare statement under `set -e`.
lane_scan_errors=0
zrl_scan_and_report_lanes Antigravity "$DIST/skills" "$DIST/shared" "$DIST/rules" || lane_scan_errors=$?
errors=$((errors + lane_scan_errors))

reviewer_primary_md="$DIST/skills/write-tests/agents/blind-coverage-auditor.md"
reviewer_alt_md="$DIST/skills/write-tests/agents/blind-coverage-auditor-alt.md"
if [ ! -f "$reviewer_primary_md" ] || [ ! -f "$reviewer_alt_md" ]; then
  echo "  ERROR: Missing Antigravity blind audit reviewer agents"
  errors=$((errors + 1))
else
  grep -q '^model: gemini-3.1-pro-high$' "$reviewer_primary_md" || { echo "  ERROR: Antigravity primary reviewer did not resolve to gemini-3.1-pro-high"; errors=$((errors + 1)); }
  grep -q '^model: gemini-3.1-pro-low$' "$reviewer_alt_md" || { echo "  ERROR: Antigravity alt reviewer did not resolve to gemini-3.1-pro-low"; errors=$((errors + 1)); }
fi

# Check for subagent_type
subagent_refs=$(grep -rln 'subagent_type:' "$DIST"/skills/*/SKILL.md 2>/dev/null || true)
if [ -n "$subagent_refs" ]; then
  echo "  ERROR: subagent_type found in SKILL.md:"
  echo "$subagent_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Check for residual ~/.claude/ paths
claude_paths=$(grep -rln '~/\.claude/' "$DIST"/skills/ "$DIST"/shared/ "$DIST"/rules/ 2>/dev/null || true)
if [ -n "$claude_paths" ]; then
  echo "  ERROR: Residual ~/.claude/ paths found:"
  echo "$claude_paths" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Agent validation: every agent should have name + description
for agent_md in "$DIST"/skills/*/agents/*.md; do
  [ -f "$agent_md" ] || continue
  has_name=$(head -10 "$agent_md" | grep -c "^name:" || true)
  has_desc=$(head -15 "$agent_md" | grep -c "^description:" || true)
  if [ "$has_name" -eq 0 ] || [ "$has_desc" -eq 0 ]; then
    echo "  WARN: Agent missing name/description: $(echo "$agent_md" | sed "s|$DIST/||")"
    warnings=$((warnings + 1))
  fi
done

# Verify shared includes were copied
include_count=$(ls "$DIST/shared/includes/"*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$include_count" -eq 0 ]; then
  echo "  ERROR: No shared include files found in $DIST/shared/includes/"
  errors=$((errors + 1))
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

# Hook validation
if [ -f "$DIST/hooks.json" ]; then
  if ! python3 -m json.tool "$DIST/hooks.json" > /dev/null 2>&1; then
    echo "  ERROR: hooks.json is not valid JSON"
    errors=$((errors + 1))
  fi
  if grep -q 'CLAUDE_PLUGIN_ROOT' "$DIST/hooks.json" 2>/dev/null; then
    echo "  ERROR: hooks.json contains CLAUDE_PLUGIN_ROOT (path leak)"
    errors=$((errors + 1))
  fi
  if grep -q '"PreToolUse"' "$DIST/hooks.json" 2>/dev/null; then
    echo "  ERROR: hooks.json contains PreToolUse (should be BeforeTool for Gemini)"
    errors=$((errors + 1))
  fi
  if grep -q '"Bash"' "$DIST/hooks.json" 2>/dev/null; then
    echo "  ERROR: hooks.json contains Bash matcher (should be run_shell_command for Gemini)"
    errors=$((errors + 1))
  fi
  if ! grep -q 'BeforeTool' "$DIST/hooks.json" 2>/dev/null; then
    echo "  ERROR: hooks.json missing BeforeTool event (required for Gemini)"
    errors=$((errors + 1))
  fi
  if ! grep -q 'run_shell_command' "$DIST/hooks.json" 2>/dev/null; then
    echo "  ERROR: hooks.json missing run_shell_command matcher (required for Gemini)"
    errors=$((errors + 1))
  fi
else
  echo "  WARN: hooks.json not found in dist"
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
echo "  Agents: $agent_count (in subdirectories)"
echo "  Shared includes: $include_count"
if [ -n "$overlay_list" ]; then
  echo "  Overlays:$overlay_list"
fi
if [ "$warnings" -gt 0 ]; then
  echo "  Warnings: $warnings"
fi
