#!/bin/bash
# Build Antigravity-adapted skills from zuvo-plugin source skills.
# Antigravity uses native agent subdirectories (no flat renaming),
# Gemini model mapping, and ~/.gemini/antigravity/ as install root.
#
# Template: build-cursor-skills.sh (simplified — no TOML, no flat agents)
#
# Usage: bash scripts/build-antigravity-skills.sh [plugin-dir]

set -euo pipefail

PLUGIN_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
DIST="$PLUGIN_DIR/dist/antigravity"

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

# --- Path Replacement (Antigravity) ---
replace_paths() {
  sed \
    -e 's|{plugin_root}/shared/|~/.gemini/antigravity/shared/|g' \
    -e 's|{plugin_root}/rules/|~/.gemini/antigravity/rules/|g' \
    -e 's|{plugin_root}/skills/|~/.gemini/antigravity/skills/|g' \
    -e 's|{plugin_root}|~/.gemini/antigravity|g' \
    -e 's|CLAUDE_PLUGIN_ROOT|GEMINI_HOME|g' \
    -e 's|~/\.claude/plugins/cache/zuvo-marketplace/zuvo/[^/]*/|~/.gemini/antigravity/|g' \
    -e 's|~/\.claude/|~/.gemini/antigravity/|g'
}

# --- Model Replacement (Antigravity — Gemini tiers) ---
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
  sed -i '' 's/CLAUDE\.md/GEMINI.md/g' "$file"
  # Platform name — only in skills, NOT shared includes
  if [[ "$file" == *"/skills/"* ]] && [[ "$file" != *"/shared/"* ]]; then
    sed -i '' 's/Claude Code/Antigravity/g' "$file"
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

  awk '
    BEGIN { in_fm=0; past_fm=0; skip_tools=0 }

    # Frontmatter boundaries
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
  ' "$src" \
    | replace_paths \
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
    | strip_tool_names \
    | normalize_unicode > "$DIST/rules/$(basename "$f")"
  # Config refs for rules: CLAUDE.md -> GEMINI.md but NOT Claude Code -> Antigravity
  sed -i '' 's/CLAUDE\.md/GEMINI.md/g' "$DIST/rules/$(basename "$f")"
done
echo "  + rules/ ($(ls "$PLUGIN_DIR"/rules/*.md 2>/dev/null | wc -l | tr -d ' ') files)"

# --- Shared includes ---
if [ -d "$PLUGIN_DIR/shared/includes" ]; then
  mkdir -p "$DIST/shared/includes"
  for f in "$PLUGIN_DIR"/shared/includes/*.md; do
    [ -f "$f" ] || continue
    cat "$f" \
      | replace_paths \
      | strip_tool_names \
      | normalize_unicode > "$DIST/shared/includes/$(basename "$f")"
    # Config refs for shared: CLAUDE.md -> GEMINI.md but NOT Claude Code -> Antigravity
    sed -i '' 's/CLAUDE\.md/GEMINI.md/g' "$DIST/shared/includes/$(basename "$f")"
  done
  echo "  + shared/includes/ ($(ls "$PLUGIN_DIR"/shared/includes/*.md 2>/dev/null | wc -l | tr -d ' ') files)"
fi

# --- Scripts ---
mkdir -p "$DIST/scripts"
for script in adversarial-review.sh benchmark.sh; do
  if [ -f "$PLUGIN_DIR/scripts/$script" ]; then
    cp "$PLUGIN_DIR/scripts/$script" "$DIST/scripts/$script"
    chmod +x "$DIST/scripts/$script"
  fi
done
echo "  + scripts/"

# ============================================================
# 2. Assemble skills + agents (in subdirectories)
# ============================================================
echo ""
echo "Assembling skills..."

skill_count=0
agent_count=0
overlay_list=""

for skill_dir in "$PLUGIN_DIR"/skills/*/; do
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

      # Skip data-only / redirect files
      is_redirect=$(head -5 "$agent" | grep -ci "REDIRECT\|canonical.*moved" || true)
      has_desc=$(head -20 "$agent" | grep -c "^description:" || true)
      is_data=$(head -5 "$agent" | grep -ci "template\|registry\|column definitions" || true)
      if [ "$is_redirect" -gt 0 ] || [ "$has_desc" -eq 0 ] || [ "$is_data" -gt 0 ]; then
        echo "    skip: $name (data-only)"
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
      cat "$ref" | replace_paths | replace_model_refs | normalize_unicode > "$DIST/skills/$skill/references/$(basename "$ref")"
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
errors=0
warnings=0

# Check for Claude Code-specific tool references
tool_refs=$(grep -rln \
  'EnterPlanMode\|ExitPlanMode\|AskUserQuestion\|TeamCreate\|SendMessage' \
  "$DIST"/skills/*/SKILL.md "$DIST"/rules/ 2>/dev/null || true)

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
