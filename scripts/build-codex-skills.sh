#!/bin/bash
# Build OpenAI Codex CLI-adapted skills from zuvo-plugin source skills.
# Codex has native sub-agents via TOML configs in ~/.codex/agents/.
# This script: generates TOML agent configs, adapts SKILL.md for Codex native
# agent spawning, normalizes paths and unicode.
#
# Usage: bash scripts/build-codex-skills.sh [plugin-dir]

set -euo pipefail

PLUGIN_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
DIST="$PLUGIN_DIR/dist/codex"

echo "Building Codex skills..."
echo "  Source: $PLUGIN_DIR"
echo "  Output: $DIST"
echo ""

# Clean previous build (preserve manually-created agents if any)
rm -rf "$DIST/skills" "$DIST/rules" "$DIST/protocols" "$DIST/shared"
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

# --- Path Replacement (reusable) ---
# Replaces ~/.claude/ paths with ~/.codex/ paths.
# Also replaces {plugin_root} tokens with ~/.codex/ paths.
# Agent paths stay as agents/ (not references/).
replace_paths() {
  sed \
    -e 's|~/.claude/skills/|~/.codex/skills/|g' \
    -e 's|~/.claude/rules/|~/.codex/rules/|g' \
    -e 's|~/.claude/plugins/cache/zuvo-marketplace/zuvo/\*/scripts/adversarial-review\.sh|~/.codex/scripts/adversarial-review.sh|g' \
    -e 's|~/.claude/|~/.codex/|g' \
    -e 's|{plugin_root}/shared/|~/.codex/shared/|g' \
    -e 's|{plugin_root}/rules/|~/.codex/rules/|g' \
    -e 's|{plugin_root}/skills/|~/.codex/skills/|g' \
    -e 's|{plugin_root}|~/.codex|g' \
    -e 's|CLAUDE_PLUGIN_ROOT|CODEX_HOME|g' \
    -e 's|../../scripts/adversarial-review\.sh|~/.codex/scripts/adversarial-review.sh|g'
}

# --- Strip Claude Code Tool Names (reusable) ---
# Replaces tool names with plain English equivalents.
# Does NOT force sequential language -- Codex has native parallelism.
strip_tool_names() {
  sed \
    -e 's/`TaskCreate`/task creation/g' \
    -e 's/`TaskUpdate`/task update/g' \
    -e 's/`TaskList`/task list/g' \
    -e 's/`TaskOutput`/task output/g' \
    -e 's/`TaskStop`/task stop/g' \
    -e 's/`TaskGet`/task status/g' \
    -e 's/`EnterPlanMode`/plan mode/g' \
    -e 's/`ExitPlanMode`/exit plan mode/g' \
    -e 's/`AskUserQuestion`/ask the user/g' \
    -e 's/TaskCreate/task creation/g' \
    -e 's/TaskUpdate/task update/g' \
    -e 's/TaskOutput/task output/g' \
    -e 's/TaskStop/task stop/g' \
    -e 's/TaskGet/task status/g' \
    -e 's/TaskList/task list/g' \
    -e 's/ExitPlanMode/finalize the plan/g' \
    -e 's/EnterPlanMode/enter plan mode/g' \
    -e 's/AskUserQuestion/ask the user/g' \
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

# --- Replace Claude-specific model names and references ---
# Replaces model names in prose (not frontmatter) and CLAUDE.md references.
replace_claude_refs() {
  sed \
    -e 's/\*\*Sonnet\*\*/\*\*gpt-5.4\*\*/g' \
    -e 's/\*\*Opus\*\*/\*\*gpt-5.3-codex\*\*/g' \
    -e 's/\*\*Haiku\*\*/\*\*gpt-5.4-mini\*\*/g' \
    -e 's/\*\*Model:\*\* Sonnet/\*\*Model:\*\* gpt-5.4/g' \
    -e 's/\*\*Model:\*\* Opus/\*\*Model:\*\* gpt-5.3-codex/g' \
    -e 's/\*\*Model:\*\* Haiku/\*\*Model:\*\* gpt-5.4-mini/g' \
    -e 's/\*\*Model routing:\*\* Sonnet | Opus/\*\*Model routing:\*\* gpt-5.4 | gpt-5.3-codex/g' \
    -e 's/model: Sonnet/model: gpt-5.4/g' \
    -e 's/model: Opus/model: gpt-5.3-codex/g' \
    -e 's/model: Haiku/model: gpt-5.4-mini/g' \
    -e 's/model: "sonnet"/model: "gpt-5.4"/g' \
    -e 's/model: "opus"/model: "gpt-5.3-codex"/g' \
    -e 's/model: "haiku"/model: "gpt-5.4-mini"/g' \
    -e 's/| Sonnet |/| gpt-5.4 |/g' \
    -e 's/| Opus |/| gpt-5.3-codex |/g' \
    -e 's/| Haiku |/| gpt-5.4-mini |/g' \
    -e 's/(model: sonnet)/(model: gpt-5.4)/g' \
    -e 's/(model: haiku)/(model: gpt-5.4-mini)/g' \
    -e 's/Use Sonnet for/Use gpt-5.4 for/g' \
    -e 's/Use Opus for/Use gpt-5.3-codex for/g' \
    -e 's/Use Haiku for/Use gpt-5.4-mini for/g' \
    -e 's/Sonnet for standard/gpt-5.4 for standard/g' \
    -e 's/Opus for complex/gpt-5.3-codex for complex/g' \
    -e 's/Opus when TIER/gpt-5.3-codex when TIER/g' \
    -e 's/Sonnet (TIER/gpt-5.4 (TIER/g' \
    -e 's/Haiku (fast, low-cost)/gpt-5.4-mini (fast, low-cost)/g' \
    -e 's/Model: Sonnet/Model: gpt-5.4/g' \
    -e 's/Model: Opus/Model: gpt-5.3-codex/g' \
    -e 's/Model: Haiku/Model: gpt-5.4-mini/g' \
    -e 's/Sonnet, Explore/gpt-5.4, Explore/g' \
    -e 's/always Sonnet/always gpt-5.4/g' \
    -e 's/-> Sonnet/-> gpt-5.4/g' \
    -e 's/-> Opus/-> gpt-5.3-codex/g' \
    -e 's/-> Haiku/-> gpt-5.4-mini/g' \
    -e 's/Sonnet implementer/gpt-5.4 implementer/g' \
    -e 's/CLAUDE\.md/AGENTS.md/g' \
    -e 's/`\.claude\/rules\/`/`rules\/`/g' \
    -e 's/\.claude\/skills\//skills\//g'
}

# --- Strip Team/Multi-Agent Sections from Protocols (reusable) ---
strip_team_sections() {
  awk '
    /^### Team Execution/ { skip=1; next }
    skip && /^### / { skip=0 }
    skip { next }
    { print }
  '
}

# --- Skill prefix for TOML naming ---
get_skill_prefix() {
  local skill="$1"
  case "$skill" in
    dependency-audit) echo "dep-audit" ;;
    write-e2e)       echo "e2e" ;;
    *)               echo "$skill" ;;
  esac
}

# --- Model mapping: CC -> Codex ---
map_model() {
  local model="$1"
  # Extract first word if model field contains prose (e.g., "per-task: sonnet ...")
  model=$(echo "$model" | awk '{print $1}' | tr -d '"')
  case "$model" in
    haiku)   echo "gpt-5.4-mini" ;;
    sonnet)  echo "gpt-5.4" ;;
    opus)    echo "gpt-5.3-codex" ;;
    per-task) echo "gpt-5.4" ;; # implementer has "per-task: sonnet for standard..."
    *)       echo "gpt-5.4" ;;
  esac
}

# --- Generate Codex TOML agent config ---
generate_agent_toml() {
  local skill="$1"
  local agent_md="$2"
  local out_dir="$3"
  local agent_name
  agent_name=$(basename "$agent_md" .md)

  # Skip team-lead agents
  if [ "$agent_name" = "team-lead" ]; then return 0; fi

  # Extract frontmatter fields
  local desc model tools_line has_write
  desc=$(head -20 "$agent_md" | grep -m1 "^description:" | sed 's/^description: *//; s/^"//; s/"$//')
  model=$(head -20 "$agent_md" | grep -m1 "^model:" | sed 's/^model: *//; s/ *#.*//')
  has_write=$(head -30 "$agent_md" | grep -cE "^\s+- (Write|Edit)" || true)

  # Check if this is a reasoning agent
  local is_reasoning
  is_reasoning=$(head -20 "$agent_md" | grep -c "^reasoning: true" || true)

  local prefix codex_model sandbox capability_line
  prefix=$(get_skill_prefix "$skill")
  codex_model=$(map_model "$model")

  if [ "$has_write" -gt 0 ]; then
    sandbox="full"
    capability_line="You ARE allowed to create and modify files. Follow write policy strictly."
  else
    sandbox="read-only"
    capability_line="NEVER modify files -- analyze and report only."
  fi

  local toml_name="${prefix}-${agent_name}"
  local toml_path="$out_dir/${toml_name}.toml"

  # Avoid duplicate "Spawned by" if already in description
  local full_desc
  if echo "$desc" | grep -qi "Spawned by"; then
    full_desc="$desc"
  else
    full_desc="${desc} Spawned by zuvo:${skill}."
  fi

  cat > "$toml_path" <<TOML
name = "${toml_name}"
description = "${full_desc}"
model = "${codex_model}"
sandbox_mode = "${sandbox}"
developer_instructions = """
You are a ${agent_name} for the zuvo:${skill} skill.
Read your full instructions at ~/.codex/skills/${skill}/agents/${agent_name}.md
Read the project AGENTS.md and rules/ directory.
${capability_line}
"""
TOML

  # Reasoning agents use gpt-5.4 with high reasoning, not gpt-5.3-codex
  if [ "$is_reasoning" -gt 0 ]; then
    sed -i '' "s|model = \"gpt-5.3-codex\"|model = \"gpt-5.4\"|" "$toml_path"
    echo 'model_reasoning_effort = "xhigh"' >> "$toml_path"
  fi
}

# --- Skill Transform for Codex ---
# Strips CC-specific sections, replaces Task spawn blocks with Codex native agent references.
transform_skill_for_codex() {
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
    in_fm && /^description: "/ { in_desc=1; sub(/^description: "/, "description: \"Zuvo -- "); print; next }
    in_fm && /^description: >/ { in_desc=1; first_desc_line=1; print; next }
    in_fm && /^description:/ { in_desc=1; sub(/^description: */, "description: Zuvo -- "); print; next }
    in_fm && in_desc && first_desc_line && /^[[:space:]]/ { first_desc_line=0; sub(/^[[:space:]]+/, "  Zuvo -- "); print; next }
    in_fm && in_desc && /^[[:space:]]/ { print; next }
    in_fm && in_desc && !/^[[:space:]]/ { in_desc=0 }
    in_fm { next }

    # --- Skip sections: Progress Tracking, Model Routing, Path Resolution ---
    /^## Progress Tracking/ { skip_section=1; next }
    /^## Model Routing/ { skip_section=1; next }
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
      # End of spawn block -- emit Codex native agent reference
      if (agent != "") {
        print "Spawn Codex agent: **" prefix "-" agent "**"
        print ""
        print "The agent reads its instructions from `~/.codex/skills/" prefix "/agents/" agent ".md`."
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
    | sed \
      -e 's/`subagent_type: "general-purpose"`//g' \
      -e 's/spawn a Task agent (subagent_type: "general-purpose") with this prompt/process each batch with this prompt/g' \
      -e 's/spawn a Task agent (`subagent_type: "general-purpose"`, `model: "sonnet"`)/process each batch/g' \
      -e 's/subagent_type: "general-purpose"//g' \
      -e 's/subagent_type: "Explore"//g' \
      -e 's/subagent_type=Explore//g' \
      -e 's/subagent_type=general-purpose//g' \
      -e 's/, , subagent_type=Explore/,/g' \
      -e 's/Task(model: "sonnet", prompt:/Codex agent with prompt:/g' \
      -e 's/Task(model: "opus", prompt:/Codex agent with prompt:/g' \
      -e 's/Task(model: "haiku", prompt:/Codex agent with prompt:/g' \
      -e 's/Spawn via Task tool\./Spawn Codex native agents./g' \
      -e 's/run_in_background=true//g' \
      -e 's/run_in_background: true//g' \
      -e 's/`Task` tool to spawn parallel sub-agents/Codex native sub-agents/g' \
      -e 's/`Task` tool/Codex native agent spawning/g' \
      -e 's/Task tool/Codex native agent spawning/g' \
      -e 's/`Agent` tool/Codex native agent spawning/g' \
      -e 's/Agent tool/Codex native agent spawning/g' \
      -e 's/These run in background while/These run in parallel while/g' \
      -e 's/(Sonnet, background)/(/g' \
      -e 's/(Haiku, background)/(/g' \
      -e 's/(parallel, background)/(parallel)/g' \
    | sed \
      -e 's/spawn a Task agent (, `model: "sonnet"`)/spawn a Codex native agent/g' \
      -e 's/spawn a Codex native agent spawning agent/spawn a Codex native agent/g' \
      -e 's/spawn one agent per batch, max [0-9]* concurrent\./spawn one Codex agent per batch (max 6 concurrent)./g' \
      -e 's/spawn one agent per dimension, max [0-9]* concurrent\./spawn one Codex agent per dimension (max 4 concurrent)./g' \
      -e 's/Spawn up to [0-9]* parallel sub-agents (model: sonnet), one per batch\./Spawn up to 6 Codex native agents, one per batch./g' \
      -e '/Cursor, Codex, no Codex/s/Codex, no Codex native agent spawning/no Codex native agent spawning/g' \
      -e '/Cursor, Antigravity, Codex/s/, Codex)/)/' \
      -e 's/Do NOT call `Agent` or Codex native agent spawnings\./Do NOT call Agent tools./g' \
      -e 's/\*\*If Codex native agent spawning is not available\*\* *(Cursor, Codex):/\*\*If Codex native agent spawning is not available\*\* (Cursor, Antigravity):/' \
      -e 's/Spawn applicable agents in parallel (use Codex native agent spawning, )\./Spawn applicable Codex native agents in parallel./' \
      -e 's/spawn via Task, , /spawn native sub-agents /g' \
      -e 's/IF Codex native agent spawning available: spawn native sub-agents/IF Codex: spawn native sub-agents/g' \
      -e 's/\*\*Spawn via Codex native agent spawning\*\* (Claude Code only):/\*\*Spawn Codex native agents:\*\*/' \
      -e 's/parallel when Codex native agent spawning is available, sequential otherwise/parallel with Codex native agents, sequential otherwise/g' \
      -e 's/\*\*Parallel\*\* (Claude Code with Codex native agent spawning available):/\*\*Parallel\*\* (Codex native agents):/' \
      -e 's/\*\*Parallel\*\* (Claude Code with Codex native agent spawning):/\*\*Parallel\*\* (Codex native agents):/' \
      -e 's/\*\*Sequential\*\* (Cursor, Codex, no Codex native agent spawning):/\*\*Sequential\*\* (Cursor, Antigravity -- no native agents):/' \
      -e 's/\*\*All other environments\*\* (Cursor, Antigravity, Codex)/\*\*All other environments\*\* (Cursor, Antigravity)/' \
      -e 's/Process all batches \*\*sequentially inline\*\* yourself/Process all batches \*\*sequentially\*\* yourself/' \
      -e '/^Perform this analysis yourself\.$/d' \
      -e 's/Spawn [0-9]* Specialist Agents (parallel Tasks)/Perform 4 Specialist Analyses Sequentially/g' \
      -e '/^IF Codex native agent spawning available:/d' \
      -e '/^IF Cursor\/Antigravity: execute inline sequentially/d' \
      -e '/^IF Codex native agent spawning: execute inline sequentially/d' \
      -e '/^IF Codex: spawn native sub-agents/d' \
      -e 's/^IF Codex: spawn Codex native agent/Spawn Codex native agent/' \
      -e 's/^IF Codex: spawn Codex native agents/Spawn Codex native agents/' \
      -e 's/\. Claude Code may parallelize.*$/\./' \
      -e 's/\*\*Claude Code only\*\* (has Codex native agent spawning):.*//' \
      -e '/^\*\*All other environments\*\* (Codex, Cursor, Antigravity):/s/\*\*All other environments\*\* (Codex, Cursor, Antigravity): //' \
      -e 's/\*\* *($/**/' \
    | awk '
      # Collapse 3+ consecutive blank lines into 2
      /^$/ { blank++; if (blank <= 2) print; next }
      { blank=0; print }
    ' \
    | awk '
      # Clean up empty agent blocks: "**Agent N: Name** ..." followed by blank lines
      # If an Agent heading has no content before the next heading, add "Lead performs this inline."
      /^\*\*Agent [0-9]+:.*\*\*/ {
        saved_agent = $0
        getline
        if ($0 ~ /^$/) {
          getline
          if ($0 ~ /^$/ || $0 ~ /^\*\*Agent/ || $0 ~ /^###/) {
            print saved_agent
            print "Lead performs this analysis inline (no dedicated Codex agent)."
            print ""
            if ($0 !~ /^$/) print $0
            next
          } else {
            print saved_agent
            print ""
            print $0
            next
          }
        } else {
          print saved_agent
          print $0
          next
        }
      }
      { print }
    ' \
    | replace_claude_refs \
    | normalize_unicode > "$dst"
}

# --- Agent Adaptation for Codex ---
# Strips model/tools from frontmatter, keeps content intact. Outputs to agents/ dir.
adapt_agent_for_codex() {
  local src="$1"
  local dst="$2"

  awk '
    BEGIN { in_fm=0; past_fm=0; skip_tools=0; skip_section=0 }

    # Frontmatter boundaries
    /^---$/ && !in_fm && !past_fm { in_fm=1; print; next }
    /^---$/ && in_fm { in_fm=0; past_fm=1; skip_tools=0; print; next }

    # Inside frontmatter: keep name + description, skip model + tools
    in_fm && /^model:/ { next }
    in_fm && /^tools:/ { skip_tools=1; next }
    in_fm && skip_tools && /^  - / { next }
    in_fm && skip_tools && !/^  - / { skip_tools=0 }
    in_fm { print; next }

    # Skip "Team Mode Verification" section
    /^### .*Team Mode/ { skip_section=1; next }
    skip_section && /^(### |## |---)/ { skip_section=0 }
    skip_section { next }

    # Body: pass through
    { print }
  ' "$src" \
    | replace_paths \
    | strip_tool_names \
    | replace_claude_refs \
    | normalize_unicode > "$dst"
}

# ============================================================
# 1. Normalize rules + protocol files
# ============================================================
echo "Normalizing rules and protocols..."
mkdir -p "$DIST/rules" "$DIST/protocols"

for f in "$PLUGIN_DIR"/rules/*.md; do
  [ -f "$f" ] && cat "$f" \
    | replace_paths \
    | strip_tool_names \
    | replace_claude_refs \
    | normalize_unicode > "$DIST/rules/$(basename "$f")"
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
      | replace_claude_refs \
      | normalize_unicode > "$DIST/shared/includes/$(basename "$f")"
  done
  echo "  + shared/includes/ ($(ls "$PLUGIN_DIR"/shared/includes/*.md 2>/dev/null | wc -l | tr -d ' ') files)"
fi

# ============================================================
# 2. Assemble skills
# ============================================================
echo ""
echo "Assembling skills..."
skill_count=0
agent_file_count=0

for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  skill=$(basename "$skill_dir")
  [ "$skill" = "shared" ] && continue
  mkdir -p "$DIST/skills/$skill"

  # --- SKILL.md: overlay or mechanical transform ---
  if [ -f "$skill_dir/codex/SKILL.codex.md" ]; then
    cp "$skill_dir/codex/SKILL.codex.md" "$DIST/skills/$skill/SKILL.md"
    echo "  + $skill (overlay)"
  else
    transform_skill_for_codex "$skill_dir/SKILL.md" "$DIST/skills/$skill/SKILL.md" "$skill"
    echo "  + $skill (auto-transform)"
  fi

  # --- Inject AUTO-DECISION mode annotation for interactive skills ---
  if [ "$skill" = "brainstorm" ] || [ "$skill" = "design" ]; then
    # Add Codex mode note after Phase 2 heading if present
    if grep -q "## Phase 2" "$DIST/skills/$skill/SKILL.md"; then
      sed -i '' '/## Phase 2/a\
\
> **Codex mode:** This skill runs autonomously. Every design decision is annotated with `[AUTO-DECISION]` including rationale and alternatives. Review the spec before running zuvo:plan.' "$DIST/skills/$skill/SKILL.md"
    fi
    # Replace interactive Q&A instructions
    sed -i '' \
      -e 's/Ask questions \*\*one at a time\*\*/Make decisions autonomously. Annotate each with \[AUTO-DECISION\]/g' \
      -e 's/Get a thumbs-up on each section/Annotate each decision with \[AUTO-DECISION\] and rationale/g' \
      "$DIST/skills/$skill/SKILL.md"
  fi

  # --- Shared files (rules.md, dimensions.md, agent-prompt.md, orchestrator-prompt.md) ---
  for f in rules.md dimensions.md agent-prompt.md orchestrator-prompt.md; do
    if [ -f "$skill_dir/$f" ]; then
      cat "$skill_dir/$f" \
        | replace_paths \
        | strip_tool_names \
        | normalize_unicode > "$DIST/skills/$skill/$f"
    fi
  done

  # --- Agents -> agents/ directory (NOT references/) ---
  if [ -d "$skill_dir/agents" ]; then
    mkdir -p "$DIST/skills/$skill/agents"
    for agent in "$skill_dir/agents/"*.md; do
      [ -f "$agent" ] || continue
      name=$(basename "$agent" .md)
      adapt_agent_for_codex "$agent" "$DIST/skills/$skill/agents/$name.md"
      echo "    agent: $name"
      agent_file_count=$((agent_file_count + 1))
    done
  fi

  # --- Source references/ (non-agent reference docs) ---
  if [ -d "$skill_dir/references" ]; then
    mkdir -p "$DIST/skills/$skill/references"
    for ref in "$skill_dir/references/"*.md; do
      [ -f "$ref" ] || continue
      name=$(basename "$ref")
      cat "$ref" | replace_paths | normalize_unicode > "$DIST/skills/$skill/references/$name"
      echo "    ref: $(basename "$ref" .md)"
    done
  fi

  # Copy cross-referenced agents (e.g., build references refactor's agents)
  if [ ! -d "$skill_dir/agents" ]; then
    cross_agents=$(grep -o '~/.claude/skills/[a-z-]*/agents/[a-z-]*\.md' "$skill_dir/SKILL.md" 2>/dev/null | sort -u || true)
    if [ -n "$cross_agents" ]; then
      mkdir -p "$DIST/skills/$skill/agents"
      echo "$cross_agents" | while IFS= read -r agent_path; do
        rel_path=$(echo "$agent_path" | sed 's|~/.claude/||')
        src_file="$PLUGIN_DIR/$rel_path"
        name=$(basename "$agent_path" .md)
        if [ -f "$src_file" ]; then
          adapt_agent_for_codex "$src_file" "$DIST/skills/$skill/agents/$name.md"
          echo "    agent: $name (cross-ref from $(echo "$rel_path" | sed 's|/agents/.*||'))"
          agent_file_count=$((agent_file_count + 1))
        fi
      done
    fi
  fi

  skill_count=$((skill_count + 1))
done

# ============================================================
# 3. Generate Codex agent TOMLs
# ============================================================
echo ""
echo "Validating agent frontmatter..."
for agent_md in "$PLUGIN_DIR"/skills/*/agents/*.md; do
  [ -f "$agent_md" ] || continue
  agent_name=$(basename "$agent_md" .md)
  [ "$agent_name" = "team-lead" ] && continue
  has_desc=$(head -20 "$agent_md" | grep -c "^description:" || true)
  if [ "$has_desc" -eq 0 ]; then
    echo "ERROR: Missing description: frontmatter in $agent_md" >&2
    exit 1
  fi
done

echo ""
echo "Generating Codex agent TOMLs..."
toml_count=0
toml_skipped=0

for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  skill=$(basename "$skill_dir")
  [ "$skill" = "shared" ] && continue
  [ ! -d "$skill_dir/agents" ] && continue

  for agent_md in "$skill_dir/agents/"*.md; do
    [ -f "$agent_md" ] || continue
    name=$(basename "$agent_md" .md)

    # Skip team-lead agents
    if [ "$name" = "team-lead" ]; then
      echo "    skip: $skill/$name (team-lead, no TOML)"
      toml_skipped=$((toml_skipped + 1))
      continue
    fi

    # Skip data-only files: redirect stubs, templates, files with no description.
    is_redirect=$(head -5 "$agent_md" | grep -ci "REDIRECT\|canonical.*moved" || true)
    has_desc=$(head -20 "$agent_md" | grep -c "^description:" || true)
    is_data=$(head -5 "$agent_md" | grep -ci "template\|registry\|column definitions" || true)
    if [ "$is_redirect" -gt 0 ] || [ "$has_desc" -eq 0 ] || [ "$is_data" -gt 0 ]; then
      echo "    skip: $skill/$name (data-only, no TOML)"
      toml_skipped=$((toml_skipped + 1))
      continue
    fi

    prefix=$(get_skill_prefix "$skill")
    toml_name="${prefix}-${name}"

    # Check for existing manually-created TOML (write-e2e)
    if [ -f "$DIST/agents/${toml_name}.toml" ]; then
      echo "    toml: $toml_name (existing, kept)"
    else
      generate_agent_toml "$skill" "$agent_md" "$DIST/agents"
      echo "    toml: $toml_name (generated)"
    fi
    toml_count=$((toml_count + 1))
  done
done

echo "  TOMLs: $toml_count generated, $toml_skipped skipped (data-only/team-lead)"

# ============================================================
# 4. Copy manifests and extra files
# ============================================================
echo ""
echo "Copying manifests..."

# Copy plugin manifest and MCP config
mkdir -p "$DIST/.codex-plugin"
cp "$PLUGIN_DIR/.codex-plugin/plugin.json" "$DIST/.codex-plugin/plugin.json"
if [ -f "$PLUGIN_DIR/.mcp.json" ]; then
  cp "$PLUGIN_DIR/.mcp.json" "$DIST/.mcp.json"
fi
# Copy openai.yaml for using-zuvo
if [ -f "$PLUGIN_DIR/skills/using-zuvo/agents/openai.yaml" ]; then
  mkdir -p "$DIST/skills/using-zuvo/agents"
  cp "$PLUGIN_DIR/skills/using-zuvo/agents/openai.yaml" "$DIST/skills/using-zuvo/agents/openai.yaml"
fi

# ============================================================
# 5. Validation
# ============================================================
echo ""
echo "Validating..."
errors=0
warnings=0

# Check for Claude Code-specific tool references (excluding agents/ which may have legacy text)
tool_refs=$(grep -rln \
  'TaskCreate\|TaskUpdate\|TaskList\|EnterPlanMode\|ExitPlanMode\|AskUserQuestion\|run_in_background\|TeamCreate\|SendMessage' \
  "$DIST"/skills/*/SKILL.md "$DIST"/rules/ "$DIST"/protocols/ 2>/dev/null || true)

if [ -n "$tool_refs" ]; then
  echo "  ERROR: Claude Code tool references found:"
  echo "$tool_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
    grep -n 'TaskCreate\|TaskUpdate\|TaskList\|EnterPlanMode\|ExitPlanMode\|AskUserQuestion\|run_in_background\|TeamCreate\|SendMessage' "$f" | head -3 | while IFS= read -r line; do
      echo "      $line"
    done
  done
  errors=$((errors + 1))
fi

# Check for untransformed ~/.claude/ paths
bad_paths=$(grep -rlnE '(~/.claude/|\.claude/)' "$DIST" 2>/dev/null || true)

if [ -n "$bad_paths" ]; then
  echo "  ERROR: Untransformed ~/.claude/ paths found:"
  echo "$bad_paths" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Check for subagent_type in SKILL.md
subagent_refs=$(grep -rln 'subagent_type:' "$DIST"/skills/*/SKILL.md 2>/dev/null || true)
if [ -n "$subagent_refs" ]; then
  echo "  ERROR: subagent_type found in SKILL.md:"
  echo "$subagent_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
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

# Check for residual CLAUDE.md references
claude_md_refs=$(grep -rln 'CLAUDE\.md' "$DIST"/skills "$DIST"/shared 2>/dev/null || true)
if [ -n "$claude_md_refs" ]; then
  echo "  WARN: Residual CLAUDE.md references (should be AGENTS.md):"
  echo "$claude_md_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  warnings=$((warnings + 1))
fi

# Check for residual Claude model names in skill prose
model_refs=$(grep -rn '\*\*Sonnet\*\*\|\*\*Opus\*\*\|\*\*Haiku\*\*\|\*\*Model:\*\* Sonnet\|\*\*Model:\*\* Opus\|\*\*Model:\*\* Haiku\|Model: Sonnet\|Model: Opus\|Model: Haiku\|model: Sonnet\|model: Opus\|model: Haiku\|Use Sonnet\|Use Opus\|Use Haiku\|Sonnet (TIER\|Haiku (fast, low-cost)\|Opus when TIER' "$DIST"/skills "$DIST"/shared 2>/dev/null || true)
  if [ -n "$model_refs" ]; then
  echo "  WARN: Residual Claude model names (Sonnet/Opus/Haiku) in skills/shared:"
  echo "$model_refs" | head -5 | while IFS= read -r line; do
    echo "    $line"
  done
  warnings=$((warnings + 1))
fi

# TOML validation: no CC model names in generated TOMLs
bad_models=$(grep -rn 'model = "sonnet"\|model = "haiku"\|model = "opus"' "$DIST"/agents/*.toml 2>/dev/null || true)
if [ -n "$bad_models" ]; then
  echo "  ERROR: CC model names in TOMLs (should be gpt-5.4/gpt-5.4-mini/gpt-5.3-codex):"
  echo "$bad_models"
  errors=$((errors + 1))
fi

# TOML validation: developer_instructions paths exist
for toml in "$DIST"/agents/*.toml; do
  [ -f "$toml" ] || continue
  toml_name=$(basename "$toml" .toml)
  agent_path=$(grep -o '~/.codex/skills/[^ ]*\.md' "$toml" | head -1 || true)
  if [ -n "$agent_path" ]; then
    # Convert ~/.codex/skills/X/agents/Y.md to dist path
    rel=$(echo "$agent_path" | sed 's|~/.codex/||')
    if [ ! -f "$DIST/$rel" ]; then
      echo "  WARN: TOML $toml_name references missing file: $rel"
      warnings=$((warnings + 1))
    fi
  fi
done

# Agent file coverage: every agent .md with model/tools should have a TOML
for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  skill=$(basename "$skill_dir")
  [ "$skill" = "shared" ] && continue
  [ ! -d "$skill_dir/agents" ] && continue

  for agent_md in "$skill_dir/agents/"*.md; do
    [ -f "$agent_md" ] || continue
    name=$(basename "$agent_md" .md)
    [ "$name" = "team-lead" ] && continue
    v_redirect=$(head -5 "$agent_md" | grep -ci "REDIRECT\|canonical.*moved" || true)
    v_desc=$(head -20 "$agent_md" | grep -c "^description:" || true)
    [ "$v_redirect" -gt 0 ] && continue
    [ "$v_desc" -eq 0 ] && continue

    prefix=$(get_skill_prefix "$skill")
    toml_name="${prefix}-${name}"
    if [ ! -f "$DIST/agents/${toml_name}.toml" ]; then
      echo "  WARN: Missing TOML for $skill/$name (expected $toml_name.toml)"
      warnings=$((warnings + 1))
    fi
  done
done

# Check that agents/ dirs exist (not references/) for multi-agent skills
for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  skill=$(basename "$skill_dir")
  [ "$skill" = "shared" ] && continue
  [ ! -d "$skill_dir/agents" ] && continue
  if [ ! -d "$DIST/skills/$skill/agents" ]; then
    echo "  WARN: Missing agents/ directory for multi-agent skill: $skill"
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
echo "  Agent files: $agent_file_count"
echo "  TOMLs: $toml_count"
echo "  Shared includes: $include_count"
if [ "$warnings" -gt 0 ]; then
  echo "  Warnings: $warnings"
fi
