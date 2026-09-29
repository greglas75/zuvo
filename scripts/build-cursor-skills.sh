#!/bin/bash
# Build Cursor v3-adapted skills from zuvo-plugin source skills.
# Cursor v3 has native sub-agents (md files in ~/.cursor/agents/),
# Task tool dispatch, and up to 4 parallel agents.
#
# This script: adapts agent frontmatter, replaces paths, normalizes unicode,
# collects agents into flat directory with skill-prefixed names.
#
# Usage: bash scripts/build-cursor-skills.sh [plugin-dir]

set -euo pipefail

PLUGIN_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# DIST root is env-overridable (B-DIST-BUILD-RACE). Every builder wrote to $PLUGIN_DIR/dist/<p>,
# and reviewer-model-builds.bats `rm -rf`s that tree in its per-test setup() — so one test file
# could truncate a directory another was asserting against. It went red about twice in ten suite
# runs and produced TWO wrong conclusions in one session: a bisect that blamed an innocent registry
# change, and a "regression" that was not one. Both were only caught by re-running in a git
# worktree with its own dist/. Unset, this is exactly the previous path, so install.sh is unchanged.
DIST="${ZUVO_DIST_ROOT:-$PLUGIN_DIR/dist}/cursor"

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"
# The reviewer-LANE grammar (plan C Task 4) — used by (a) the leftover-lane scan in Validation and
# (b) zrl_agent_model_known (fix round 2, G1: moved here from a byte-identical per-build copy —
# CQ14/CQ20 in the round-1 quality review), the STRICT reader's own grammar (zrl_frontmatter_model)
# read ahead of adapt_agent_for_cursor's awk, so an agent with no readable `model:` or a value this
# build cannot map fails the build BY NAME instead of silently becoming `inherit` (fix round 1, C1 —
# the same defect class Task 3 closed in build-codex-skills.sh's map_model). `review-primary` /
# `review-alt` are the router's lane NAMES, and prose (shared/includes/test-reviewer-routing.md,
# env-compat.md, session-state.md, execute/retro) quotes them to say what to do with the router's
# answer; this build used to rewrite them dist-wide, so every installed copy of those docs disagreed
# with the router it documents — sourcing this library is what lets the leftover scan reuse ITS
# lenient grammar instead of a sixth copy of the same regex.
# Guarded the way build-codex-skills.sh guards its MODEL_REGISTRY source: a clear, build-specific
# error before anything is read, plus (stronger than Codex's guard) a check that sourcing actually
# defined what this build calls — a truncated or renamed library fails loudly here, not with a
# confusing "command not found" mid-build.
LANES_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/reviewer-lanes.sh"
if [ ! -f "$LANES_LIB" ]; then
  echo "ERROR: reviewer-lanes.sh not found: $LANES_LIB — the Cursor build cannot validate reviewer lanes without it" >&2
  exit 1
fi
. "$LANES_LIB"
# zrl_require_functions is itself part of what a broken library may lack, so check it first.
if ! declare -F zrl_require_functions >/dev/null 2>&1; then
  echo "ERROR: zrl_require_functions is not defined after sourcing $LANES_LIB — the library is missing or incomplete" >&2
  exit 1
fi
zrl_require_functions "$LANES_LIB" zrl_read_agent_model zrl_check_agent_model zrl_frontmatter_model \
  zrl_agent_model_known zrl_strip_bom_crlf zrl_scan_and_report_lanes zrl_scan_md zrl_count_refs \
  zrl_show_refs || exit 1


echo "Building Cursor skills..."
echo "  Source: $PLUGIN_DIR"
echo "  Output: $DIST"
echo ""

# Clean previous build
rm -rf "$DIST/skills" "$DIST/rules" "$DIST/shared" "$DIST/agents"
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

# --- Path Replacement (Cursor) ---
# CRITICAL: Replace ALL relative paths (../../) with absolute ~/.cursor/ paths.
# Relative paths work in Claude Code (plugin resolves from SKILL.md location)
# but NOT in Cursor where the agent reads instructions and resolves from CWD.
replace_paths() {
  sed \
    -e 's|{plugin_root}/shared/|~/.cursor/shared/|g' \
    -e 's|{plugin_root}/rules/|~/.cursor/rules/|g' \
    -e 's|{plugin_root}/skills/|~/.cursor/skills/|g' \
    -e 's|{plugin_root}|~/.cursor|g' \
    -e 's|CLAUDE_PLUGIN_ROOT|CURSOR_HOME|g' \
    -e 's|~/.claude/plugins/cache/zuvo-marketplace/zuvo/\*/scripts/adversarial-review\.sh|~/.cursor/scripts/adversarial-review.sh|g' \
    -e 's|../../../shared/includes/|~/.cursor/shared/includes/|g' \
    -e 's|../../../shared/|~/.cursor/shared/|g' \
    -e 's|../../../scripts/|~/.cursor/scripts/|g' \
    -e 's|../../../rules/|~/.cursor/rules/|g' \
    -e 's|../../../skills/|~/.cursor/skills/|g' \
    -e 's|../../shared/includes/|~/.cursor/shared/includes/|g' \
    -e 's|../../shared/|~/.cursor/shared/|g' \
    -e 's|../../scripts/|~/.cursor/scripts/|g' \
    -e 's|../../rules/|~/.cursor/rules/|g' \
    -e 's|../../skills/|~/.cursor/skills/|g'
}

# --- Strip Claude Code Tool Names ---
# Lighter than Codex — Cursor v3 has Task tool, but not CC-specific tools.
strip_tool_names() {
  sed \
    -e 's/`EnterPlanMode`/plan mode/g' \
    -e 's/`ExitPlanMode`/exit plan mode/g' \
    -e 's/`AskUserQuestion`/ask the user/g' \
    -e 's/EnterPlanMode/enter plan mode/g' \
    -e 's/ExitPlanMode/finalize the plan/g' \
    -e 's/AskUserQuestion/ask the user/g' \
    -e 's/`TaskCreate`/sub-agent dispatch/g' \
    -e 's/`TaskUpdate`/task update/g' \
    -e 's/`TaskList`/task list/g' \
    -e 's/`TaskOutput`/task output/g' \
    -e 's/`TaskStop`/task stop/g' \
    -e 's/`TaskGet`/task status/g' \
    -e 's/TaskCreate/sub-agent dispatch/g' \
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

# --- Replace Claude-specific references for Cursor ---
# Keep Anthropic model names (Cursor supports Claude models natively).
# Only change structural references.
replace_cursor_refs() {
  sed \
    -e 's/`\.claude\/rules\/`/`rules\/`/g' \
    -e 's/\.claude\/skills\//skills\//g'
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

# --- Skill Transform for Cursor v3 ---
# Adapts spawn blocks for Cursor sub-agent dispatch.
# Keeps Task tool concept (Cursor v3 has it), caps concurrency at 4.
transform_skill_for_cursor() {
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
      # End of spawn block -- emit Cursor sub-agent reference
      if (agent != "") {
        print "Dispatch sub-agent: **" prefix "-" agent "**"
        print ""
        print "The agent reads its instructions from `~/.cursor/agents/" prefix "-" agent ".md`."
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
      -e 's/subagent_type: "general-purpose"//g' \
      -e 's/subagent_type: "Explore"//g' \
      -e 's/subagent_type=Explore//g' \
      -e 's/subagent_type=general-purpose//g' \
      -e 's/run_in_background=true//g' \
      -e 's/run_in_background: true//g' \
      -e 's/`Task` tool to spawn parallel sub-agents/Cursor sub-agents (max 4 parallel)/g' \
      -e 's/`Task` tool/Cursor sub-agent dispatch/g' \
      -e 's/Task tool/Cursor sub-agent dispatch/g' \
      -e 's/`Agent` tool/Cursor sub-agent dispatch/g' \
      -e 's/Agent tool/Cursor sub-agent dispatch/g' \
      -e 's/(Sonnet, background)/(/g' \
      -e 's/(Haiku, background)/(/g' \
      -e 's/(parallel, background)/(parallel)/g' \
      -e 's/max [0-9]* parallel/max 4 parallel/g' \
      -e 's/Max [0-9]* parallel/Max 4 parallel/g' \
      -e 's/max [0-9]* concurrent/max 4 concurrent/g' \
      -e 's/up to [0-9]* parallel/up to 4 parallel/g' \
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
    | replace_cursor_refs \
    | normalize_unicode \
    | sed \
      -e "s|skills/${skill}/agents/\([a-z][-a-z]*\)\.md|~/.cursor/agents/${prefix}-\1.md|g" \
      -e "s|skills/dependency-audit/agents/\([a-z][-a-z]*\)\.md|~/.cursor/agents/dep-audit-\1.md|g" \
      -e "s|skills/write-e2e/agents/\([a-z][-a-z]*\)\.md|~/.cursor/agents/e2e-\1.md|g" \
      -e "s|skills/\([a-z][-a-z]*\)/agents/\([a-z][-a-z]*\)\.md|~/.cursor/agents/\1-\2.md|g" \
    | sed \
      -e "s|^\(agents/\)\([a-z][-a-z]*\)\.md|~/.cursor/agents/${prefix}-\2.md|g" \
      -e "s|\([^/]\)\(agents/\)\([a-z][-a-z]*\)\.md|\1~/.cursor/agents/${prefix}-\3.md|g" \
    > "$dst"
}

# --- Agent Adaptation for Cursor v3 ---
# Converts CC agent frontmatter to Cursor v3 format:
#   model: sonnet → model: inherit
#   tools: [Read, Grep] → readonly: true
#   tools: [Write, Edit, ...] → readonly: false
#   reasoning: true → removed (not a Cursor concept)
adapt_agent_for_cursor() {
  local src="$1"
  local dst="$2"
  local skill="$3"
  local agent_name
  agent_name=$(basename "$src" .md)
  local prefix
  prefix=$(get_skill_prefix "$skill")
  local full_name="${prefix}-${agent_name}"

  # Detect if agent has write tools (scan full frontmatter block). Reads through
  # zrl_strip_bom_crlf (fix round 3, A3 — replaces round 2's `\r?` regex tolerance): a BOM or CRLF
  # source is normalized to plain LF before this awk ever sees it, so `/^---$/` needs no tolerance
  # of its own.
  local has_write
  has_write=$(zrl_strip_bom_crlf < "$src" | awk '/^---$/{n++; if(n==2) exit} n==1{print}' | grep -cE "^\s+- (Write|Edit)" || true)
  # `grep -c` always prints a count (0 included), even on empty input, so this is normally
  # unreachable -- explicit anyway (fix round 3, A8): a genuinely empty pipeline result must not
  # make the `-gt` comparison below error out on a non-numeric value.
  has_write="${has_write:-0}"

  local readonly_val
  if [ "$has_write" -gt 0 ]; then
    readonly_val="false"
  else
    readonly_val="true"
  fi

  zrl_strip_bom_crlf < "$src" | awk -v full_name="$full_name" -v readonly_val="$readonly_val" '
    BEGIN { in_fm=0; past_fm=0; skip_tools=0; name_done=0 }

    # Frontmatter boundaries. The input is pre-normalized to LF-only, BOM-free (fix round 3, A3 —
    # replaces round 2 CR-tolerant regexes, which only handled CRLF and never handled a BOM at
    # all): without that normalization, a BOM or CRLF file could pass the C1 gate (which reads its
    # model: value through zrl_frontmatter_model, which DOES tolerate both) and then fall through
    # here unconverted, because `/^---$/` would never match a `\xef\xbb\xbf---` or `---\r` line and
    # in_fm would never be set -- the whole frontmatter, model: line included, copied through as
    # plain body text instead of being adapted.
    /^---$/ && !in_fm && !past_fm { in_fm=1; print; next }
    /^---$/ && in_fm {
      in_fm=0; past_fm=1; skip_tools=0
      # Inject readonly before closing frontmatter
      print "readonly: " readonly_val
      print "---"
      next
    }

    # Inside frontmatter
    in_fm && /^name:/ {
      print "name: " full_name
      name_done=1
      next
    }
    in_fm && /^description:/ { print; next }
    in_fm && /^model:/ {
      # Map model: sonnet/opus/haiku → inherit or fast
      if ($0 ~ /haiku/) {
        print "model: fast"
      } else if ($0 ~ /review-primary/ || $0 ~ /review-alt/) {
        print "model: inherit"
      } else {
        print "model: inherit"
      }
      next
    }
    in_fm && /^reasoning:/ { next }  # Drop — not a Cursor concept
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
  ' \
    | replace_paths \
    | strip_tool_names \
    | replace_cursor_refs \
    | normalize_unicode > "$dst"
}

# ============================================================
# 1. Normalize rules + shared includes
# ============================================================
echo "Normalizing rules and shared includes..."
mkdir -p "$DIST/rules"

for f in "$PLUGIN_DIR"/rules/*.md; do
  [ -f "$f" ] && cat "$f" \
    | replace_paths \
    | strip_tool_names \
    | replace_cursor_refs \
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
      | replace_cursor_refs \
      | normalize_unicode > "$DIST/shared/includes/$rel"
  done < <(find "$PLUGIN_DIR/shared/includes" -type f -name "*.md" -print0)
  # shell includes (e.g. model-registry.sh) — PLAIN copy, NO markdown transforms (they would mangle
  # the concrete model ids the registry holds).
  while IFS= read -r -d '' f; do
    rel="${f#$PLUGIN_DIR/shared/includes/}"
    mkdir -p "$DIST/shared/includes/$(dirname "$rel")"
    cp "$f" "$DIST/shared/includes/$rel"
  done < <(find "$PLUGIN_DIR/shared/includes" -type f -name "*.sh" -print0)
  echo "  + shared/includes/ ($(find "$PLUGIN_DIR/shared/includes" -type f \( -name '*.md' -o -name '*.sh' \) | wc -l | tr -d ' ') files)"
fi

# ============================================================
# 2. Assemble skills + collect agents
# ============================================================
echo ""
echo "Assembling skills..."

skill_count=0
agent_count=0
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
  if [ -f "$skill_dir/cursor/SKILL.cursor.md" ]; then
    cp "$skill_dir/cursor/SKILL.cursor.md" "$DIST/skills/$skill/SKILL.md"
    echo "  + $skill (overlay)"
  else
    transform_skill_for_cursor "$skill_dir/SKILL.md" "$DIST/skills/$skill/SKILL.md" "$skill"
    echo "  + $skill (auto-transform)"
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

  # --- Agents → flat agents/ directory with skill prefix ---
  if [ -d "$skill_dir/agents" ]; then
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
      # was silently dropped before).
      agent_model_rc=0
      agent_model_value=$(zrl_read_agent_model "$agent") || agent_model_rc=$?

      # Skip data-only files -- only when there is NO readable model: (fix round 3, A1) and the
      # file is actually readable (fix round 2, G2): head/grep both return empty on a permission
      # error, which used to misclassify an unreadable agent as "data-only" and skip it silently,
      # before the model check below ever saw it. An unreadable file falls through to that check
      # instead, which reports it by name. root reads everything, so this gate is a no-op when the
      # build runs as root (fix round 3: no fix needed here — the G2 tests already skip themselves
      # under root, since chmod 000 cannot lock root out either).
      # Only status 1 (no model key at all) can be data: 2 with a readable file means the normalized
      # copy failed, and 3 no temp file — both are errors, never a silent data-only skip.
      if [ "$agent_model_rc" -eq 1 ] && [ -r "$agent" ]; then
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
      if ! zrl_check_agent_model Cursor "$agent" "$agent_model_rc" "${agent_model_value:-}"; then
        errors=$((errors + 1))
        continue
      fi

      prefix=$(get_skill_prefix "$skill")
      adapt_agent_for_cursor "$agent" "$DIST/agents/${prefix}-${name}.md" "$skill"
      echo "    agent: ${prefix}-${name}"
      agent_count=$((agent_count + 1))
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

  skill_count=$((skill_count + 1))
done

# Copy openai.yaml for using-zuvo (if exists)
if [ -f "$PLUGIN_DIR/skills/using-zuvo/agents/openai.yaml" ]; then
  mkdir -p "$DIST/skills/using-zuvo/agents"
  cp "$PLUGIN_DIR/skills/using-zuvo/agents/openai.yaml" "$DIST/skills/using-zuvo/agents/openai.yaml"
fi

# Machine-readable VERSION marker (root + skills/) so a Cursor fleet install is
# version-identifiable even without a manifest reader.
if [ -f "$PLUGIN_DIR/VERSION" ]; then
  cp "$PLUGIN_DIR/VERSION" "$DIST/VERSION"
  mkdir -p "$DIST/skills"; cp "$PLUGIN_DIR/VERSION" "$DIST/skills/VERSION"
fi

# ============================================================
# 2.5. Platform Block Stripping
# Cursor build: keep CURSOR blocks, strip CODEX and ANTIGRAVITY.
# ============================================================
echo ""
echo "Stripping non-Cursor platform blocks..."
strip_count=0
while IFS= read -r -d '' md; do
  if grep -q "<!-- PLATFORM:" "$md" 2>/dev/null; then
    sed_i \
      -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
      -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
      -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
      -e '/<!-- PLATFORM:CURSOR -->/d' \
      -e '/<!-- \/PLATFORM:CURSOR -->/d' \
      "$md"
    strip_count=$((strip_count + 1))
  fi
done < <(find "$DIST/skills" "$DIST/shared/includes" "$DIST/rules" -type f -name "*.md" -print0 2>/dev/null)
echo "  Stripped platform blocks from $strip_count files"

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

# Check for subagent_type in SKILL.md
subagent_refs=$(grep -rln 'subagent_type:' "$DIST"/skills/*/SKILL.md 2>/dev/null || true)
if [ -n "$subagent_refs" ]; then
  echo "  ERROR: subagent_type found in SKILL.md:"
  echo "$subagent_refs" | while IFS= read -r f; do
    echo "    $(echo "$f" | sed "s|$DIST/||")"
  done
  errors=$((errors + 1))
fi

# Agent validation: every agent .md should have name + description
for agent_md in "$DIST"/agents/*.md; do
  [ -f "$agent_md" ] || continue
  has_name=$(head -10 "$agent_md" | grep -c "^name:" || true)
  has_desc=$(head -15 "$agent_md" | grep -c "^description:" || true)
  if [ "$has_name" -eq 0 ] || [ "$has_desc" -eq 0 ]; then
    echo "  WARN: Agent missing name/description: $(basename "$agent_md")"
    warnings=$((warnings + 1))
  fi
done

# Agent validation: check for readonly field
for agent_md in "$DIST"/agents/*.md; do
  [ -f "$agent_md" ] || continue
  has_readonly=$(head -15 "$agent_md" | grep -c "^readonly:" || true)
  if [ "$has_readonly" -eq 0 ]; then
    echo "  WARN: Agent missing readonly field: $(basename "$agent_md")"
    warnings=$((warnings + 1))
  fi
done

# Check for residual CC model names in agents (should be inherit/fast)
bad_models=$(grep -rHn 'model: sonnet\|model: opus\|model: haiku\|model: "sonnet"\|model: "opus"\|model: "haiku"' "$DIST"/agents/*.md 2>/dev/null || true)
if [ -n "$bad_models" ]; then
  echo "  ERROR: CC model names in agents (should be inherit/fast):"
  echo "$bad_models" | head -5
  errors=$((errors + 1))
fi

# Abstract reviewer lanes must be resolved IN AGENT FRONTMATTER (plan C Task 4). This is the
# shared lenient scan (scripts/lib/reviewer-lanes.sh) restricted to a `model:` key inside a
# file's own leading frontmatter block, so it catches a lane adapt_agent_for_cursor's awk failed
# to recognize (BOM, indentation, a quoted key, CRLF, any case, flow/comma syntax, …) without
# flagging the same words when prose quotes the router's lane names. EVERY tree this build writes
# a `.md` into is scanned (fix round 1, C3/C4: rules/ was missing — a planted rules/ frontmatter
# lane went unreported until then; fix round 2, E3: references/*.md nests under
# skills/<skill>/references/, already inside $DIST/skills — a planted references/ fixture was
# verified caught by this same list before E3 changed anything, so no path was added for it.
# VERSION and the scripts/hooks copies are not markdown, so there is no other `.md`-writing tree).
# The scan fails CLOSED on a value it cannot parse at all (a YAML block scalar, an unclosed quote)
# — the old whole-file substring gate silently let such a file through; this is intended (plan C
# Task 3 design), and it is proven harmless below (fix round 1, C7): all 48 real agents build with
# zero leftover — see docs/runbook/testing.md.
# zrl_scan_and_report_lanes (fix round 3, A4/W12) runs the capture in its OWN subshell with its
# own trap — this script's exit path is never touched by it — and returns the error count; it must
# not run as a bare statement under `set -e`.
lane_scan_errors=0
zrl_scan_and_report_lanes Cursor "$DIST/skills" "$DIST/shared" "$DIST/agents" "$DIST/rules" || lane_scan_errors=$?
errors=$((errors + lane_scan_errors))

reviewer_primary_md="$DIST/agents/write-tests-blind-coverage-auditor.md"
reviewer_alt_md="$DIST/agents/write-tests-blind-coverage-auditor-alt.md"
if [ ! -f "$reviewer_primary_md" ] || [ ! -f "$reviewer_alt_md" ]; then
  echo "  ERROR: Missing Cursor blind audit reviewer agents"
  errors=$((errors + 1))
else
  grep -q '^model: inherit$' "$reviewer_primary_md" || { echo "  ERROR: Cursor primary reviewer did not resolve to inherit"; errors=$((errors + 1)); }
  grep -q '^model: inherit$' "$reviewer_alt_md" || { echo "  ERROR: Cursor alt reviewer did not resolve to inherit"; errors=$((errors + 1)); }
fi

# Verify shared includes were copied
include_count=$(find "$DIST/shared/includes" -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
if [ "$include_count" -eq 0 ]; then
  echo "  ERROR: No shared include files found in $DIST/shared/includes/"
  errors=$((errors + 1))
fi
if [ ! -f "$DIST/shared/includes/banned-vocabulary/core.md" ] || [ ! -f "$DIST/shared/includes/banned-vocabulary/languages/en.md" ]; then
  echo "  ERROR: Missing recursive banned-vocabulary includes in Cursor dist"
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
echo "  Agents: $agent_count (flat in agents/)"
echo "  Shared includes: $include_count"
if [ "$warnings" -gt 0 ]; then
  echo "  Warnings: $warnings"
fi
