#!/bin/bash
# Build OpenAI Codex CLI-adapted skills from zuvo-plugin source skills.
# Codex has native sub-agents via TOML configs in ~/.codex/agents/.
# This script: generates TOML agent configs, adapts SKILL.md for Codex native
# agent spawning, normalizes paths and unicode.
#
# Usage: bash scripts/build-codex-skills.sh [plugin-dir]

set -euo pipefail

PLUGIN_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# DIST root is env-overridable (B-DIST-BUILD-RACE). Every builder wrote to $PLUGIN_DIR/dist/<p>,
# and reviewer-model-builds.bats `rm -rf`s that tree in its per-test setup() — so one test file
# could truncate a directory another was asserting against. It went red about twice in ten suite
# runs and produced TWO wrong conclusions in one session: a bisect that blamed an innocent registry
# change, and a "regression" that was not one. Both were only caught by re-running in a git
# worktree with its own dist/. Unset, this is exactly the previous path, so install.sh is unchanged.
DIST="${ZUVO_DIST_ROOT:-$PLUGIN_DIR/dist}/codex"

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"
# The reviewer-lane grammar (lib/reviewer-lanes.sh): the strict frontmatter rewriter, the per-agent gate
# the other three builds use too (zrl_agent_gate), the lenient leftover scans and the model-id check,
# shared with install.sh. Found beside this file, like portable.sh, and checked the way the other builds
# check it: it exists, and sourcing it defined every function this build calls.
LANES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/reviewer-lanes.sh"
if [ ! -f "$LANES_LIB" ]; then
  echo "ERROR: reviewer-lanes.sh not found: $LANES_LIB — the Codex build cannot validate reviewer lanes without it" >&2
  exit 1
fi
. "$LANES_LIB"
declare -F zrl_require_fns >/dev/null 2>&1 \
  || { echo "ERROR: zrl_require_fns is not defined after sourcing $LANES_LIB — the library is missing or incomplete" >&2; exit 1; }
zrl_require_fns "$LANES_LIB" zrl_is_model_id zrl_is_route_word zrl_rewrite_lanes zrl_strip_bom_crlf zrl_agent_gate \
  zrl_scan_and_report_lanes zrl_scan_and_report_toml_lanes zrl_toml_model || exit 1

# Every model id this build writes comes from the registry of the tree being built, never from literals
# in this file (plan C Task 3; the literals were a second copy that had to be kept in step by hand, and
# the tier literals went stale: they named gpt-5.4 / gpt-5.4-mini after the account stopped serving
# them). The registry is `VAR="${VAR:-default}"`, so an id already set in the environment wins — how a
# test builds with a swapped id, and how a user pins one. Fails the build closed: a TOML naming a model
# the registry never gave is worse than no build.
#   lanes  review-primary -> ZUVO_MODEL_CODEX_PRIMARY, review-alt -> ZUVO_MODEL_CODEX_REVIEW_ALT (derived
#          from _ALT there) — the variables reviewer-model-route.sh answers for those lanes;
#   tiers  opus -> ZUVO_MODEL_CODEX_PRIMARY, sonnet -> ZUVO_MODEL_CODEX_ALT, haiku -> ZUVO_MODEL_CODEX_SMALL
#          — the router's strong_primary / strong_alt / small writer lanes on a Codex host.
# An id is what the router's is_model_id accepts (zrl_is_model_id is that grammar), so the build never
# refuses an id the router would route to, nor emits one it would refuse.
MODEL_REGISTRY="$PLUGIN_DIR/shared/includes/model-registry.sh"
if [ ! -f "$MODEL_REGISTRY" ] || [ ! -r "$MODEL_REGISTRY" ]; then
  echo "ERROR: model registry not found or unreadable: $MODEL_REGISTRY — the Codex build takes every model id from it and does not guess one" >&2
  exit 1
fi
# shellcheck source=shared/includes/model-registry.sh
if ! . "$MODEL_REGISTRY"; then
  echo "ERROR: model registry could not be sourced: $MODEL_REGISTRY — the Codex build takes every model id from it and does not guess one" >&2
  exit 1
fi
for _id_var in ZUVO_MODEL_CODEX_PRIMARY ZUVO_MODEL_CODEX_REVIEW_ALT ZUVO_MODEL_CODEX_ALT ZUVO_MODEL_CODEX_SMALL; do
  if ! zrl_is_model_id "${!_id_var:-}"; then
    echo "ERROR: $_id_var from $MODEL_REGISTRY is not a single model id: '${!_id_var:-}'" >&2
    exit 1
  fi
  # A route word passes the router's id charset (zrl_is_model_id stays that charset, character for
  # character) but names no model: refused HERE, before a single file is written, not left for the
  # leftover scan to find in every TOML afterwards.
  if zrl_is_route_word "${!_id_var}"; then
    echo "ERROR: $_id_var from $MODEL_REGISTRY is [${!_id_var}], a route word, not a model id" >&2
    exit 1
  fi
done
unset _id_var
CODEX_TIER_OPUS="$ZUVO_MODEL_CODEX_PRIMARY"
CODEX_TIER_SONNET="$ZUVO_MODEL_CODEX_ALT"
CODEX_TIER_HAIKU="$ZUVO_MODEL_CODEX_SMALL"


echo "Building Codex skills..."
echo "  Source: $PLUGIN_DIR"
echo "  Output: $DIST"
echo ""

# Clean previous build. $DIST/agents MUST be cleaned too: the TOML loop below
# skips regeneration when a file already exists, so leaving stale TOMLs here
# froze every agent config at its first-ever build (model/sandbox/instruction
# changes never propagated). All TOMLs are generated from skills/*/agents/*.md,
# so a clean rebuild loses nothing — there are no hand-authored TOMLs in dist.
rm -rf "$DIST/skills" "$DIST/rules" "$DIST/protocols" "$DIST/shared" "$DIST/agents"
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
# Also replaces {plugin_root} tokens and ALL relative paths (../../) with ~/.codex/.
# CRITICAL: Relative paths work in Claude Code (plugin resolves from SKILL.md location)
# but NOT in Codex where the agent reads instructions and resolves from CWD.
replace_paths() {
  sed \
    -e 's|~/\.claude/skills/|~/.codex/skills/|g' \
    -e 's|~/\.claude/rules/|~/.codex/rules/|g' \
    -e 's|~/\.claude/plugins/cache/zuvo-marketplace/zuvo/\*/scripts/adversarial-review\.sh|~/.codex/scripts/adversarial-review.sh|g' \
    -e 's|\$HOME/\.claude/|$HOME/.codex/|g' \
    -e 's|~/\.claude/|~/.codex/|g' \
    -e 's|{plugin_root}/shared/|~/.codex/shared/|g' \
    -e 's|{plugin_root}/rules/|~/.codex/rules/|g' \
    -e 's|{plugin_root}/skills/|~/.codex/skills/|g' \
    -e 's|{plugin_root}|~/.codex|g' \
    -e 's|CLAUDE_PLUGIN_ROOT|CODEX_HOME|g' |
  sed -E \
    -e 's#^(\.\./){2,3}(shared|scripts|rules|skills)/#~/.codex/\2/#' \
    -e 's#([^-A-Za-z0-9_~\./])(\.\./){2,3}(shared|scripts|rules|skills)/#\1~/.codex/\3/#g'
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
    -e "s/\*\*Sonnet\*\*/\*\*$CODEX_TIER_SONNET\*\*/g" \
    -e "s/\*\*Opus\*\*/\*\*$CODEX_TIER_OPUS\*\*/g" \
    -e "s/\*\*Haiku\*\*/\*\*$CODEX_TIER_HAIKU\*\*/g" \
    -e "s/\*\*Model:\*\* Sonnet/\*\*Model:\*\* $CODEX_TIER_SONNET/g" \
    -e "s/\*\*Model:\*\* Opus/\*\*Model:\*\* $CODEX_TIER_OPUS/g" \
    -e "s/\*\*Model:\*\* Haiku/\*\*Model:\*\* $CODEX_TIER_HAIKU/g" \
    -e "s/\*\*Model routing:\*\* Sonnet | Opus/\*\*Model routing:\*\* $CODEX_TIER_SONNET | $CODEX_TIER_OPUS/g" \
    -e "s/model: Sonnet/model: $CODEX_TIER_SONNET/g" \
    -e "s/model: Opus/model: $CODEX_TIER_OPUS/g" \
    -e "s/model: Haiku/model: $CODEX_TIER_HAIKU/g" \
    -e "s/model: \"sonnet\"/model: \"$CODEX_TIER_SONNET\"/g" \
    -e "s/model: \"opus\"/model: \"$CODEX_TIER_OPUS\"/g" \
    -e "s/model: \"haiku\"/model: \"$CODEX_TIER_HAIKU\"/g" \
    -e "s/| Sonnet |/| $CODEX_TIER_SONNET |/g" \
    -e "s/| Opus |/| $CODEX_TIER_OPUS |/g" \
    -e "s/| Haiku |/| $CODEX_TIER_HAIKU |/g" \
    -e "s/(model: sonnet)/(model: $CODEX_TIER_SONNET)/g" \
    -e "s/(model: haiku)/(model: $CODEX_TIER_HAIKU)/g" \
    -e "s/Use Sonnet for/Use $CODEX_TIER_SONNET for/g" \
    -e "s/Use Opus for/Use $CODEX_TIER_OPUS for/g" \
    -e "s/Use Haiku for/Use $CODEX_TIER_HAIKU for/g" \
    -e "s/Sonnet for standard/$CODEX_TIER_SONNET for standard/g" \
    -e "s/Opus for complex/$CODEX_TIER_OPUS for complex/g" \
    -e "s/Opus when TIER/$CODEX_TIER_OPUS when TIER/g" \
    -e "s/Sonnet (TIER/$CODEX_TIER_SONNET (TIER/g" \
    -e "s/Haiku (fast, low-cost)/$CODEX_TIER_HAIKU (fast, low-cost)/g" \
    -e "s/Model: Sonnet/Model: $CODEX_TIER_SONNET/g" \
    -e "s/Model: Opus/Model: $CODEX_TIER_OPUS/g" \
    -e "s/Model: Haiku/Model: $CODEX_TIER_HAIKU/g" \
    -e "s/Sonnet, Explore/$CODEX_TIER_SONNET, Explore/g" \
    -e "s/always Sonnet/always $CODEX_TIER_SONNET/g" \
    -e "s/-> Sonnet/-> $CODEX_TIER_SONNET/g" \
    -e "s/-> Opus/-> $CODEX_TIER_OPUS/g" \
    -e "s/-> Haiku/-> $CODEX_TIER_HAIKU/g" \
    -e "s/Sonnet implementer/$CODEX_TIER_SONNET implementer/g" \
    -e 's/CLAUDE\.md/AGENTS.md/g' \
    -e 's/`\.claude\/rules\/`/`rules\/`/g' \
    -e 's/\.claude\/skills\//skills\//g'
}

# replace_reviewer_lane_refs_codex — stdin filter: a reviewer LANE named as a model (a column-0
# `model:` inside the leading `---` block, the whole value the lane) becomes the registry's Codex id
# for it — the strict rewriter of lib/reviewer-lanes.sh. Nothing else is touched: outside frontmatter
# `review-primary` / `review-alt` / `cross-vendor` are the ROUTER's lane names, and the documents
# quoting them must keep saying what reviewer-model-route.sh says (plan C Task 3). Most frontmatter
# `model:` lines never reach this filter — the SKILL and agent adapters drop the key and the TOML takes
# its id from map_model — so this is the net for any that do; the lenient leftover scans in Validation
# fail the build on whatever still gets past.
replace_reviewer_lane_refs_codex() {
  zrl_rewrite_lanes "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_MODEL_CODEX_REVIEW_ALT"
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
# map_model <value> — the Codex model id for an agent's frontmatter model value, one zrl_agent_gate has
# already accepted (zrl_agent_model_known: the exact tier and lane words, or a quoted "per-task: …"
# descriptor), so all four builds accept and refuse the same agents; status 1 (no output) for any other
# value, a guard that the gate makes unreachable. Values are printed with printf, never echo.
# A LANE resolves to the registry's id for it, and so does a TIER (CODEX_TIER_*, set where the registry
# is loaded): opus is the registry's primary, sonnet its alt, haiku its small id. replace_claude_refs
# writes the SAME three variables into the prose of every document, so a TOML and the text describing
# it always name one model. Hard-coded tier ids lived here once and outlived the models: every
# non-reviewer agent shipped with gpt-5.4 / gpt-5.4-mini, which model-registry.sh records as refused on
# the account. A per-task descriptor ("sonnet for standard complexity, opus for complex") gets the
# sonnet tier, its standard case.
map_model() {
  case "$1" in
    review-primary) printf '%s\n' "$ZUVO_MODEL_CODEX_PRIMARY" ;;
    review-alt)     printf '%s\n' "$ZUVO_MODEL_CODEX_REVIEW_ALT" ;;
    haiku)          printf '%s\n' "$CODEX_TIER_HAIKU" ;;
    sonnet)         printf '%s\n' "$CODEX_TIER_SONNET" ;;
    opus)           printf '%s\n' "$CODEX_TIER_OPUS" ;;
    \"per-task:*\"|\'per-task:*\') printf '%s\n' "$CODEX_TIER_SONNET" ;;
    *) return 1 ;;
  esac
}

# --- Generate Codex TOML agent config ---
# agent_capability_line <agent-md> — the TOML's write-policy line: an agent whose first 30 lines list a
# Write or Edit tool may modify files; any other is told to analyze and report only.
agent_capability_line() {
  local has_write
  has_write=$(head -30 "$1" | grep -cE "^\s+- (Write|Edit)" || true)
  if [ "${has_write:-0}" -gt 0 ]; then
    echo "You ARE allowed to create and modify files. Follow write policy strictly."
  else
    echo "NEVER modify files -- analyze and report only."
  fi
}

# generate_agent_toml <skill> <agent-md> <out-dir> <model-value> — the model value is the one
# zrl_agent_gate accepted for this agent (the caller runs the gate first).
generate_agent_toml() {
  local skill="$1"
  local agent_md="$2"
  local out_dir="$3"
  local model="$4"
  local agent_name
  agent_name=$(basename "$agent_md" .md)

  # Skip team-lead agents
  if [ "$agent_name" = "team-lead" ]; then return 0; fi

  # Extract frontmatter fields. An agent this cannot take gets NO TOML and one ERROR counted in
  # toml_errors (Validation adds it to the build's errors) — never a default id or description.
  # Returns 0 either way, so this stays a plain statement under set -e for every OTHER failure in it.
  local desc
  # awk reads the file itself (no `head | grep` pipe that could die of SIGPIPE under pipefail).
  # `|| desc=""`: on an UNREADABLE agent awk fails, and under the build's set -e a bare assignment would
  # abort the whole build here with awk's own message. The gate the caller runs first already names such
  # a file; this keeps a caller that skipped it from turning the read into a crash.
  desc=$(awk 'NR > 20 { exit } /^description:/ { sub(/^description: */, ""); print; exit }' "$agent_md" 2>/dev/null) || desc=""
  desc="${desc#\"}"
  desc="${desc%\"}"
  if [ -z "$desc" ]; then
    echo "  ERROR: $agent_md has no \`description:\` in its first 20 lines — the Codex build does not invent one"
    toml_errors=$((toml_errors + 1))
    return 0
  fi
  # Check if this is a reasoning agent
  local is_reasoning
  is_reasoning=$(head -20 "$agent_md" | grep -c "^reasoning: true" || true)

  local prefix codex_model capability_line
  prefix=$(get_skill_prefix "$skill")
  if ! codex_model=$(map_model "$model"); then
    echo "  ERROR: $agent_md: model value '$model' has no Codex id (map_model) — the gate accepted a value this build cannot map"
    toml_errors=$((toml_errors + 1))
    return 0
  fi

  # Sandbox is intentionally NOT pinned here. Generated agents inherit the
  # user's global Codex profile (e.g. danger-full-access + never) instead of a
  # hardcoded sandbox_mode that would override the CLI profile. Analysis agents
  # stay read-only via the instruction below, not via a seatbelt sandbox.
  capability_line="$(agent_capability_line "$agent_md")"

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
developer_instructions = """
You are a ${agent_name} for the zuvo:${skill} skill.
Read your full instructions at ~/.codex/skills/${skill}/agents/${agent_name}.md
Read the project AGENTS.md and rules/ directory.
${capability_line}
"""
TOML

  # A reasoning agent runs at xhigh reasoning effort. On the opus TIER (`model: opus`) it runs the sonnet
  # tier instead; a review lane (review-primary / review-alt) keeps the id its lane resolved to, even when
  # that id is the opus tier's — the lane is the router's choice of reviewer model, not a tier to trade.
  # The `$model = opus` test is that exemption: for a lane agent $model is the lane word, never `opus`.
  if [ "$is_reasoning" -gt 0 ]; then
    if [ "$codex_model" = "$CODEX_TIER_OPUS" ] && [ "$model" = opus ]; then
      sed_i "s|^model = \"$CODEX_TIER_OPUS\"\$|model = \"$CODEX_TIER_SONNET\"|" "$toml_path"
    fi
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
      -e 's/Spawn via Task tool\./Single-agent on Codex: perform each role INLINE as a sequential checkpoint pass (thread spawning forbidden)./g' \
      -e 's/run_in_background=true//g' \
      -e 's/run_in_background: true//g' \
      -e 's/`Task` tool to spawn parallel sub-agents/Codex native sub-agents/g' \
      -e 's/`Task` tool/Task tool (Claude-only; on Codex run this role INLINE, single-agent)/g' \
      -e 's/Task tool/Task tool (Claude-only; on Codex run this role INLINE, single-agent)/g' \
      -e 's/`Agent` tool/Task tool (Claude-only; on Codex run this role INLINE, single-agent)/g' \
      -e 's/Agent tool/Task tool (Claude-only; on Codex run this role INLINE, single-agent)/g' \
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
      -e 's/\*\*Spawn via Codex native agent spawning\*\* (Claude Code only):/\*\*On Codex: run these roles INLINE, sequentially (no threads):\*\*/' \
      -e 's/parallel when Codex native agent spawning is available, sequential otherwise/parallel with Codex native agents, sequential otherwise/g' \
      -e 's/\*\*Parallel\*\* (Claude Code with Codex native agent spawning available):/\*\*Sequential on Codex (parallel is Claude-only):\*\*/' \
      -e 's/\*\*Parallel\*\* (Claude Code with Codex native agent spawning):/\*\*Sequential on Codex (parallel is Claude-only):\*\*/' \
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
    | replace_reviewer_lane_refs_codex \
    | normalize_unicode > "$dst"
}

# --- Agent Adaptation for Codex ---
# Strips model/tools from frontmatter, keeps content intact. Outputs to agents/ dir. Reads through
# zrl_strip_bom_crlf, as the other builds' adapters do: a BOM or CRLF first line is `---` for the awk,
# so the frontmatter (and its model key) is recognized in exactly the agents the gate reads a model from.
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
  ' < <(zrl_strip_bom_crlf < "$src") \
    | replace_paths \
    | strip_tool_names \
    | replace_claude_refs \
    | replace_reviewer_lane_refs_codex \
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
    | replace_reviewer_lane_refs_codex \
    | normalize_unicode > "$DIST/rules/$(basename "$f")"
done
echo "  + rules/ ($(ls "$PLUGIN_DIR"/rules/*.md 2>/dev/null | wc -l | tr -d ' ') files)"

# --- Shared includes ---
if [ -d "$PLUGIN_DIR/shared/includes" ]; then
  mkdir -p "$DIST/shared/includes"
  while IFS= read -r -d '' f; do
    rel="${f#$PLUGIN_DIR/shared/includes/}"
    mkdir -p "$DIST/shared/includes/$(dirname "$rel")"
    cat "$f" \
      | replace_paths \
      | strip_tool_names \
      | replace_claude_refs \
      | replace_reviewer_lane_refs_codex \
      | normalize_unicode > "$DIST/shared/includes/$rel"
  done < <(find "$PLUGIN_DIR/shared/includes" -type f -name "*.md" -print0)
  # shell includes (e.g. model-registry.sh) — PLAIN copy, NO markdown transforms: replace_claude_refs
  # / reviewer-lane rewrites would mangle the concrete model ids the registry exists to hold.
  while IFS= read -r -d '' f; do
    rel="${f#$PLUGIN_DIR/shared/includes/}"
    mkdir -p "$DIST/shared/includes/$(dirname "$rel")"
    cp "$f" "$DIST/shared/includes/$rel"
  done < <(find "$PLUGIN_DIR/shared/includes" -type f -name "*.sh" -print0)
  echo "  + shared/includes/ ($(find "$PLUGIN_DIR/shared/includes" -type f \( -name '*.md' -o -name '*.sh' \) | wc -l | tr -d ' ') files)"
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

  # Systemic codex rule — every skill, both overlay and auto-transform paths

  # --- Inject AUTO-DECISION mode annotation for interactive skills ---
  if [ "$skill" = "brainstorm" ] || [ "$skill" = "design" ]; then
    # Add Codex mode note after Phase 2 heading if present
    if grep -q "## Phase 2" "$DIST/skills/$skill/SKILL.md"; then
      sed_i '/## Phase 2/a\
\
> **Codex mode:** This skill runs autonomously. Every design decision is annotated with `[AUTO-DECISION]` including rationale and alternatives. Review the spec before running zuvo:plan.' "$DIST/skills/$skill/SKILL.md"
    fi
    # Replace interactive Q&A instructions
    sed_i \
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
      # An unreadable agent is not copied (its read would abort the build with a bare tool error); the
      # gate in the TOML section below reports it by name and counts it.
      [ -r "$agent" ] || continue
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
      transform_skill_for_codex "$ref" "$DIST/skills/$skill/references/$name" "$skill"
      echo "    ref: $(basename "$ref" .md)"
    done
  fi

  # Cross-skill agent references need NO copy step: SKILL.md files reference
  # other skills' agents as ../../skills/<x>/agents/<y>.md (content-expand →
  # write-article's anti-slop-reviewer, write-article → brainstorm's
  # code-explorer), replace_paths rewrites that to ~/.codex/skills/<x>/agents/,
  # and the referenced skill ships its own agents/ dir above. A former copy
  # block here grepped for the legacy ~/.claude/skills/... form, which no
  # SKILL.md uses anymore — it silently matched nothing (removed 2026-08-01).
  # Guard: if the legacy form ever reappears, nothing materializes its agent
  # in any dist — fail the build instead of shipping a broken reference.
  if grep -q '~/.claude/skills/[a-z-]*/agents/' "$skill_dir/SKILL.md" 2>/dev/null; then
    echo "ERROR: $skill/SKILL.md uses the legacy ~/.claude/skills/.../agents/ path form — use ../../skills/<x>/agents/<y>.md" >&2
    exit 1
  fi

  skill_count=$((skill_count + 1))
done

# Cross-skill agent reference integrity: every ~/.codex/skills/<x>/agents/<y>.md
# that a built SKILL.md points at must exist in THIS dist — a missed
# replace_paths variant or a skill that stopped shipping its agents/ dir would
# otherwise 404 silently at agent-invocation time (review 81e425d, R-1).
missing_refs=0
for built_skill in "$DIST"/skills/*/SKILL.md; do
  [ -f "$built_skill" ] || continue
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ ! -f "$DIST/${ref#\~/.codex/}" ]; then
      echo "ERROR: $(basename "$(dirname "$built_skill")")/SKILL.md references missing agent in dist: $ref" >&2
      missing_refs=$((missing_refs + 1))
    fi
  done < <(grep -oE '~/.codex/skills/[a-z-]+/agents/[a-z-]+\.md' "$built_skill" | sort -u)
done
if [ "$missing_refs" -gt 0 ]; then
  echo "ERROR: $missing_refs cross-skill agent reference(s) point at files absent from the dist" >&2
  exit 1
fi

# ============================================================
# 3. Generate Codex agent TOMLs
# ============================================================
echo ""
echo "Validating agent frontmatter..."
for agent_md in "$PLUGIN_DIR"/skills/*/agents/*.md; do
  [ -f "$agent_md" ] || continue
  agent_name=$(basename "$agent_md" .md)
  [ "$agent_name" = "team-lead" ] && continue
  # An unreadable file has no description to find here; the gate below reports it by name.
  [ -r "$agent_md" ] || continue
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
toml_errors=0   # agents the build cannot turn into a TOML (generate_agent_toml, a name collision); counted in Validation

for skill_dir in "$PLUGIN_DIR"/skills/*/; do
  # Without the glob's trailing slash, so every path this loop names reads .../<skill>/agents/<file>.md.
  skill_dir="${skill_dir%/}"
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

    # The gate (lib/reviewer-lanes.sh, the same in all four builds): accepted (its model value in
    # ZRL_AGENT_MODEL), data-only, or refused with its ERROR line already printed — one error, no TOML.
    gate=0
    zrl_agent_gate Codex "$agent_md" || gate=$?
    case "$gate" in
      0) ;;
      10) echo "    skip: $skill/$name (data-only, no TOML)"; toml_skipped=$((toml_skipped + 1)); continue ;;
      *) toml_errors=$((toml_errors + 1)); continue ;;
    esac

    prefix=$(get_skill_prefix "$skill")
    toml_name="${prefix}-${name}"

    # $DIST/agents is cleaned at build start (the `rm -rf` near the top), so every TOML here is written
    # by THIS run from its agent's current model and the registry — no earlier build's TOML survives.
    # One that already exists can only mean two source agents map to one TOML name (a skill prefix
    # collision, e.g. write-e2e -> e2e): one TOML would stand for both and the second agent would never
    # be checked. That is an ERROR, named — never "existing, kept".
    if [ -f "$DIST/agents/${toml_name}.toml" ]; then
      echo "  ERROR: ${toml_name}.toml would be written twice — $agent_md maps to the same TOML name as an agent before it; rename one"
      toml_errors=$((toml_errors + 1))
      continue
    else
      generate_agent_toml "$skill" "$agent_md" "$DIST/agents" "$ZRL_AGENT_MODEL"
      if [ ! -f "$DIST/agents/${toml_name}.toml" ]; then
        echo "    toml: $toml_name (NOT generated: see the ERROR above)"
        continue
      fi
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
# Machine-readable VERSION marker (root + skills/) so a Codex fleet install is
# version-identifiable even without a manifest reader.
if [ -f "$PLUGIN_DIR/VERSION" ]; then
  cp "$PLUGIN_DIR/VERSION" "$DIST/VERSION"
  mkdir -p "$DIST/skills"; cp "$PLUGIN_DIR/VERSION" "$DIST/skills/VERSION"
fi
if [ -f "$PLUGIN_DIR/.mcp.json" ]; then
  cp "$PLUGIN_DIR/.mcp.json" "$DIST/.mcp.json"
fi
# Copy openai.yaml for using-zuvo
if [ -f "$PLUGIN_DIR/skills/using-zuvo/agents/openai.yaml" ]; then
  mkdir -p "$DIST/skills/using-zuvo/agents"
  cp "$PLUGIN_DIR/skills/using-zuvo/agents/openai.yaml" "$DIST/skills/using-zuvo/agents/openai.yaml"
fi

# ============================================================
# 4b. Hooks
# ============================================================
echo ""
echo "Assembling hooks..."

mkdir -p "$DIST/hooks"

# Copy hooks.codex.json as hooks.json (the plugin manifest references ./hooks.json)
if [ -f "$PLUGIN_DIR/hooks/hooks.codex.json" ]; then
  cat "$PLUGIN_DIR/hooks/hooks.codex.json" \
    | replace_paths \
    > "$DIST/hooks.json"
  echo "  + hooks.json (from hooks.codex.json)"
fi

# Copy hook scripts with path replacement
# block-no-verify.sh added (Codex PreToolUse Bash). zuvo-stop-pipeline-gate.sh is
# NOT shipped — Codex has no Stop hook; pre-push + CI cover it.
# refactor-safety-gate.sh is NOT wired as a Codex event hook — it is the git pre-commit/pre-push
# gate that zuvo:refactor Phase 0 self-installs into the repo. It must still ship, or that phase
# reports "gate/install script not found" on every Codex run (false installer-missing telemetry,
# and the Definition-of-Done bind silently absent).
for hook_script in block-no-verify.sh route-suite-through-verify.sh require-inventory-first.sh pre-push-gate.sh pre-commit-adversarial-gate.sh refactor-safety-gate.sh codex-poll-guard.sh session-start; do
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

# Copy run-hook.cmd as-is (polyglot wrapper, no path replacement needed)
if [ -f "$PLUGIN_DIR/hooks/run-hook.cmd" ]; then
  cp "$PLUGIN_DIR/hooks/run-hook.cmd" "$DIST/hooks/run-hook.cmd"
  echo "  + hooks/run-hook.cmd"
fi

# ============================================================
# 4.5. Platform Block Stripping
# Codex build: keep CODEX blocks, strip CURSOR and ANTIGRAVITY.
# ============================================================
echo ""
echo "Stripping non-Codex platform blocks..."
strip_count=0
while IFS= read -r -d '' md; do
  if grep -q "<!-- PLATFORM:" "$md" 2>/dev/null; then
    sed_i \
      -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
      -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
    -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
      -e '/<!-- PLATFORM:CODEX -->/d' \
      -e '/<!-- \/PLATFORM:CODEX -->/d' \
      "$md"
    strip_count=$((strip_count + 1))
  fi
done < <(find "$DIST/skills" "$DIST/shared/includes" "$DIST/rules" -type f -name "*.md" -print0 2>/dev/null)
echo "  Stripped platform blocks from $strip_count files"

# ============================================================
# 5. Validation
# ============================================================
echo ""
echo "Validating..."
# Each agent that got no TOML (its ERROR line is in the TOML section above) is one error.
errors=$toml_errors
warnings=0

# Check for Claude Code-specific tool references (excluding agents/ which may have legacy text)
# references/*.md is IN SCOPE: it is copied verbatim into the dist above, so
# without it a Claude-only tool name just has to move out of SKILL.md to ship.
tool_refs=$(grep -rln \
  'TaskCreate\|TaskUpdate\|TaskList\|EnterPlanMode\|ExitPlanMode\|AskUserQuestion\|run_in_background\|TeamCreate\|SendMessage' \
  "$DIST"/skills/*/SKILL.md "$DIST"/skills/*/references/*.md "$DIST"/rules/ "$DIST"/protocols/ 2>/dev/null || true)

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

# Check for untransformed ~/.claude/ paths.
# Flag only genuine PLUGIN-INSTALL paths: a tilde `~/.claude/` (the transformer
# rewrites all of these → must never survive) and the install subdirs
# `.claude/{plugins,skills,rules,agents}/`. Do NOT flag repo-CONTENT references
# like `.claude/worktrees/` — that is a directory-exclusion glob used during file
# counting (e.g. db-audit) and is correct as-is on every platform; Claude Code
# creates `.claude/worktrees/` regardless of which agent runs the skill.
bad_paths=$(grep -rlnE '(~/\.claude/|\.claude/(plugins|skills|rules|agents)/)' "$DIST" 2>/dev/null || true)

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
model_refs=$(grep -rHn '\*\*Sonnet\*\*\|\*\*Opus\*\*\|\*\*Haiku\*\*\|\*\*Model:\*\* Sonnet\|\*\*Model:\*\* Opus\|\*\*Model:\*\* Haiku\|Model: Sonnet\|Model: Opus\|Model: Haiku\|model: Sonnet\|model: Opus\|model: Haiku\|Use Sonnet\|Use Opus\|Use Haiku\|Sonnet (TIER\|Haiku (fast, low-cost)\|Opus when TIER' "$DIST"/skills "$DIST"/shared 2>/dev/null || true)
  if [ -n "$model_refs" ]; then
  echo "  WARN: Residual Claude model names (Sonnet/Opus/Haiku) in skills/shared:"
  echo "$model_refs" | head -5 | while IFS= read -r line; do
    echo "    $line"
  done
  warnings=$((warnings + 1))
fi

# TOML validation: no CC model names in generated TOMLs
bad_models=$(grep -rHn 'model = "sonnet"\|model = "haiku"\|model = "opus"' "$DIST"/agents/*.toml 2>/dev/null || true)
if [ -n "$bad_models" ]; then
  echo "  ERROR: CC model names in TOMLs (should be the registry's ids: $CODEX_TIER_SONNET / $CODEX_TIER_HAIKU / $CODEX_TIER_OPUS):"
  echo "$bad_models"
  errors=$((errors + 1))
fi

# Validation: no route word survives as a MODEL — in the model key of any agent TOML, or in a model key
# of the leading frontmatter of any emitted .md — in any spelling. These are the lenient scans of
# lib/reviewer-lanes.sh, independent of the strict rewriter above, so what the rewriter could not take
# fails the build here, named, one error per reference — reported by the same helpers, in the same
# words, as the other three builds. Prose is deliberately NOT checked: there the lane words are the
# router's vocabulary and must survive (plan C Task 3).
# Fail closed: no TOML to scan is an error of its own; a missing directory or a scan that could not
# read fails the helper, which still shows what it had found before it stopped. The TOML list is built
# by a test per path, not a nullglob, so no shell option is changed.
agent_tomls=()
for t in "$DIST"/agents/*.toml; do
  if [ -f "$t" ]; then agent_tomls+=("$t"); fi
done
lane_scan_errors=0
if [ "${#agent_tomls[@]}" -eq 0 ]; then
  echo "  ERROR: no agent TOMLs in $DIST/agents to scan for unresolved reviewer lanes"
  errors=$((errors + 1))
else
  zrl_scan_and_report_toml_lanes Codex "${agent_tomls[@]}" || lane_scan_errors=$?
  errors=$((errors + lane_scan_errors))
fi
lane_scan_errors=0
zrl_scan_and_report_lanes Codex "$DIST/skills" "$DIST/shared" "$DIST/rules" "$DIST/protocols" || lane_scan_errors=$?
errors=$((errors + lane_scan_errors))

# The two review lanes are meant to be two models. One id for both still builds — an account may serve
# only one, and the router labels that review same-model-fallback at run time — but it is said here,
# where the person who pinned the ids reads it.
if [ "$ZUVO_MODEL_CODEX_PRIMARY" = "$ZUVO_MODEL_CODEX_REVIEW_ALT" ]; then
  echo "  WARN: review-primary and review-alt both resolve to $ZUVO_MODEL_CODEX_PRIMARY (ZUVO_MODEL_CODEX_PRIMARY = ZUVO_MODEL_CODEX_REVIEW_ALT) — the two blind-audit reviewers are one model"
  warnings=$((warnings + 1))
fi

# The two blind-audit reviewers resolve to the registry's ids — the value of their model key compared,
# however the key is spelled.
reviewer_primary_toml="$DIST/agents/write-tests-blind-coverage-auditor.toml"
reviewer_alt_toml="$DIST/agents/write-tests-blind-coverage-auditor-alt.toml"
if [ ! -f "$reviewer_primary_toml" ] || [ ! -f "$reviewer_alt_toml" ]; then
  echo "  ERROR: Missing Codex blind audit reviewer TOMLs"
  errors=$((errors + 1))
else
  got_model="$(zrl_toml_model "$reviewer_primary_toml" || true)"
  if [ "$got_model" != "$ZUVO_MODEL_CODEX_PRIMARY" ]; then
    echo "  ERROR: Codex primary reviewer TOML resolved to [$got_model], not the registry's ZUVO_MODEL_CODEX_PRIMARY ($ZUVO_MODEL_CODEX_PRIMARY)"
    errors=$((errors + 1))
  fi
  got_model="$(zrl_toml_model "$reviewer_alt_toml" || true)"
  if [ "$got_model" != "$ZUVO_MODEL_CODEX_REVIEW_ALT" ]; then
    echo "  ERROR: Codex alt reviewer TOML resolved to [$got_model], not the registry's ZUVO_MODEL_CODEX_REVIEW_ALT ($ZUVO_MODEL_CODEX_REVIEW_ALT)"
    errors=$((errors + 1))
  fi
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
    [ -r "$agent_md" ] || continue   # already an ERROR from the gate above
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
# `|| true`: no includes, or no includes dir, must reach the check below, not end the build under pipefail.
include_count=$({ find "$DIST/shared/includes" -type f -name "*.md" 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$include_count" -eq 0 ]; then
  echo "  ERROR: No shared include files found in $DIST/shared/includes/"
  errors=$((errors + 1))
fi
if [ ! -f "$DIST/shared/includes/banned-vocabulary/core.md" ] || [ ! -f "$DIST/shared/includes/banned-vocabulary/languages/en.md" ]; then
  echo "  ERROR: Missing recursive banned-vocabulary includes in Codex dist"
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
  if grep -q '~/\.claude/' "$DIST/hooks.json" 2>/dev/null; then
    echo "  ERROR: hooks.json contains ~/.claude/ path (path leak)"
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
echo "  Agent files: $agent_file_count"
echo "  TOMLs: $toml_count"
echo "  Shared includes: $include_count"
if [ "$warnings" -gt 0 ]; then
  echo "  Warnings: $warnings"
fi
