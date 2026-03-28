# Implementation Plan: Codex Compatibility Layer

**Spec:** docs/specs/2026-03-27-codex-compatibility-spec.md
**Created:** 2026-03-27
**Tasks:** 12
**Estimated complexity:** 3 complex (build script core, build script transforms, TOML generation), 9 standard

## Architecture Summary

The Codex layer adds a build pipeline that transforms zuvo-plugin source files into Codex-compatible output in `dist/codex/`. No source skill files are modified -- the build script operates on copies.

**Components:**
- `scripts/build-codex-skills.sh` (~750 lines) -- core build pipeline, adapted from toolkit's 670-line script
- `.codex-plugin/plugin.json` -- committed Codex manifest at repo root
- `.mcp.json` -- optional CodeSift MCP config
- `skills/using-zuvo/agents/openai.yaml` -- implicit invocation for router
- `shared/includes/env-compat.md` -- updated with Codex CLI vs App distinction
- `shared/includes/run-logger.md` -- updated with Codex path logic
- `shared/includes/codex-agent-registry.md` -- new TOML generation manifest
- `dist/codex/` -- build output (gitignored): adapted skills, ~35 TOMLs, rules

**Key adaptations from toolkit script:**
- Path: `skills/shared/includes/` -> `shared/includes/`
- New: `{plugin_root}` token replacement (153 occurrences)
- New: ToolSearch -> direct MCP tool references
- Changed: `map_model()` three-tier (haiku->gpt-5.4-mini, sonnet->gpt-5.4, opus->gpt-5.3-codex)
- Changed: TOML description suffix `Spawned by /<skill>.` -> `Spawned by zuvo:<skill>.`
- New: `reasoning: true` frontmatter flag -> `model_reasoning_effort = "xhigh"` in TOML
- New: Validation checks for residual `{plugin_root}`, ToolSearch, line count warnings

## Technical Decisions

- **Agent frontmatter**: Manual prerequisite (add YAML frontmatter to 9 agent files before build)
- **ToolSearch replacement**: sed in `strip_tool_names()` for single-line pattern; scoped AWK for fenced-block pattern (2 files)
- **`.codex-plugin/plugin.json`**: Static committed file (not generated)
- **`{plugin_root}` tokens**: Replace at build time with `~/.codex/` paths via extended `replace_paths()`
- **Build output**: `dist/codex/` gitignored (not a separate branch)
- **team-lead.md**: Excluded from TOML generation by name (not a dispatched agent)

## Quality Strategy

- **Testing approach**: No test framework. Three tiers: (1) shellcheck linting, (2) grep/wc assertions on build output, (3) full build + AC verification
- **CQ gates active**: CQ3 (frontmatter validation), CQ8 (`set -euo pipefail`), CQ14 (zuvo replaces toolkit -- no duplication concern)
- **Key risks**: env-compat.md global regression (additive-only edits), `{plugin_root}` replacement correctness (153 occurrences), agent frontmatter completeness (build must fail if missing)
- **QA caught**: `run-logger.md` needs Codex path logic (not in original spec's modified files list)

## Task Breakdown

### Task 1: Add YAML frontmatter to pipeline agent files

**Files:** `skills/brainstorm/agents/code-explorer.md`, `domain-researcher.md`, `business-analyst.md`, `spec-reviewer.md`, `skills/plan/agents/architect.md`, `tech-lead.md`, `qa-engineer.md`, `plan-reviewer.md`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

This is a configuration change (TDD protocol: does NOT apply). Add proper YAML frontmatter to 8 agent files so the TOML generator can parse them. Add `reasoning: true` to 4 agents that do analytical/review work.

- [ ] Add frontmatter to `skills/brainstorm/agents/code-explorer.md`:
  ```yaml
  ---
  name: code-explorer
  description: "Scans codebase for relevant modules, patterns, similar code, and blast radius."
  model: sonnet
  tools:
    - Read
    - Grep
    - Glob
  ---
  ```
- [ ] Add frontmatter to `skills/brainstorm/agents/domain-researcher.md`:
  ```yaml
  ---
  name: domain-researcher
  description: "Researches libraries, APIs, established approaches, and prior art."
  model: sonnet
  tools:
    - Read
  ---
  ```
- [ ] Add frontmatter to `skills/brainstorm/agents/business-analyst.md`:
  ```yaml
  ---
  name: business-analyst
  description: "Identifies edge cases, acceptance criteria, and problem landscape."
  model: sonnet
  tools:
    - Read
    - Grep
    - Glob
  ---
  ```
- [ ] Add frontmatter to `skills/brainstorm/agents/spec-reviewer.md`:
  ```yaml
  ---
  name: spec-reviewer
  description: "Reviews design specifications for completeness, consistency, and implementability."
  model: sonnet
  reasoning: true
  tools:
    - Read
  ---
  ```
- [ ] Add frontmatter to `skills/plan/agents/architect.md` (replace the `> Model: Sonnet | Type: Explore` line):
  ```yaml
  ---
  name: architect
  description: "Maps component boundaries, data flow, interfaces, and dependency graph."
  model: sonnet
  reasoning: true
  tools:
    - Read
    - Grep
    - Glob
  ---
  ```
- [ ] Add frontmatter to `skills/plan/agents/tech-lead.md`:
  ```yaml
  ---
  name: tech-lead
  description: "Selects patterns, libraries, makes implementation decisions based on architecture."
  model: sonnet
  tools:
    - Read
    - Grep
    - Glob
  ---
  ```
- [ ] Add frontmatter to `skills/plan/agents/qa-engineer.md`:
  ```yaml
  ---
  name: qa-engineer
  description: "Assesses testability, identifies risk areas, pre-checks quality gates."
  model: sonnet
  tools:
    - Read
    - Grep
    - Glob
  ---
  ```
- [ ] Add frontmatter to `skills/plan/agents/plan-reviewer.md`:
  ```yaml
  ---
  name: plan-reviewer
  description: "Validates plan task ordering, dependency correctness, and spec coverage."
  model: sonnet
  reasoning: true
  tools:
    - Read
  ---
  ```
- [ ] Do NOT add frontmatter to `skills/plan/agents/team-lead.md` -- it is not a dispatched agent. Leave as-is.
- [ ] Verify: `grep -rL '^description:' skills/*/agents/*.md | grep -v team-lead` returns empty (all agents across ALL skills have description — covers brainstorm, plan, and execute)
- [ ] Verify: `grep -rl '^reasoning: true' skills/*/agents/*.md` returns exactly 3 files: spec-reviewer.md, architect.md, plan-reviewer.md
- [ ] Commit: `feat: add YAML frontmatter to 8 pipeline agent files for Codex TOML generation`

Note: `quality-reviewer.md` in execute/agents/ already has `reasoning: true` equivalent behavior but no explicit flag. Add it:

- [ ] Add `reasoning: true` to `skills/execute/agents/quality-reviewer.md` frontmatter
- [ ] Verify: `grep -rl '^reasoning: true' skills/*/agents/*.md` returns 4 files

---

### Task 2: Create static config files

**Files:** `.codex-plugin/plugin.json`, `.mcp.json`, `skills/using-zuvo/agents/openai.yaml`, `.gitignore`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

Configuration change (TDD protocol: does NOT apply).

**OQ1 gate (P0):** Before creating `openai.yaml`, verify `allow_implicit_invocation` against Codex plugin documentation at developers.openai.com/codex/skills or a live Codex install. If the field is NOT confirmed:
- Skip creating `openai.yaml`
- Instead, create `dist/codex/agents/zuvo-router.toml` in Task 6 with `developer_instructions` containing the full routing table from `skills/using-zuvo/SKILL.md`

- [ ] **GATE: Verify OQ1** — confirm `allow_implicit_invocation` is a real Codex field. Document result.
- [ ] Create `.codex-plugin/plugin.json`:
  ```json
  {
    "name": "zuvo",
    "version": "1.0.0",
    "description": "Multi-agent skill ecosystem for structured software development. 33 skills with quality gates, code exploration, and evidence-based review.",
    "author": {
      "name": "Zuvo",
      "email": "hello@zuvo.dev"
    },
    "homepage": "https://zuvo.dev",
    "license": "MIT",
    "skills": "./skills/",
    "mcpServers": "./.mcp.json"
  }
  ```
- [ ] Create `.mcp.json`:
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
- [ ] Create `skills/using-zuvo/agents/openai.yaml`:
  ```yaml
  policy:
    allow_implicit_invocation: true
  ```
- [ ] Update `.gitignore` -- add `dist/` entry
- [ ] Verify: `cat .codex-plugin/plugin.json | python3 -m json.tool` exits 0 (valid JSON)
- [ ] Verify: `cat .mcp.json | python3 -m json.tool` exits 0
- [ ] Verify: `grep -q 'dist/' .gitignore`
- [ ] Commit: `feat: add Codex plugin manifest, MCP config, and openai.yaml`

---

### Task 3: Copy build script + adapt base structure

**Files:** `scripts/build-codex-skills.sh`
**Complexity:** complex
**Dependencies:** none
**Model routing:** Opus

- [ ] RED: Verify script doesn't exist yet:
  ```bash
  test ! -f scripts/build-codex-skills.sh && echo "PASS: not yet created"
  ```
- [ ] GREEN: Copy `build-codex-skills.sh` from `/Users/greglas/DEV/claude-code-toolkit/scripts/build-codex-skills.sh` to `scripts/build-codex-skills.sh`. Then apply these structural adaptations:
  1. Change `TOOLKIT_DIR` variable to `PLUGIN_DIR`
  2. Change shared includes source path from `"$PLUGIN_DIR/skills/shared/includes"` to `"$PLUGIN_DIR/shared/includes"`
  3. Change shared includes output path from `"$DIST/skills/shared/includes"` to `"$DIST/shared/includes"`
  4. Add `set -euo pipefail` (toolkit uses only `set -e`)
  5. Update header comment to reference zuvo-plugin
  6. Verify the rules copy loop reads from `"$PLUGIN_DIR/rules/"` (should work as-is)
  7. Remove the root-level `*.md` protocol copy block (zuvo has no root protocol files except README.md)
- [ ] Verify: `bash -n scripts/build-codex-skills.sh` exits 0 (syntax valid)
- [ ] Verify: `shellcheck scripts/build-codex-skills.sh` has no errors (warnings OK)
- [ ] Commit: `feat: add build-codex-skills.sh -- base structure adapted from toolkit`

---

### Task 4: Adapt replace_paths() and strip_tool_names()

**Files:** `scripts/build-codex-skills.sh`
**Complexity:** complex
**Dependencies:** Task 3
**Model routing:** Opus

- [ ] RED: Create a test fixture file and run the function:
  ```bash
  mkdir -p /tmp/zuvo-build-test
  cat > /tmp/zuvo-build-test/test-skill.md << 'EOF'
  Read `{plugin_root}/shared/includes/codesift-setup.md`
  Read `{plugin_root}/rules/cq-patterns.md`
  Path: `CLAUDE_PLUGIN_ROOT`
  ToolSearch(query="codesift", max_results=20)
  EOF
  # After sourcing the script's functions, piping through replace_paths and strip_tool_names
  # should produce zero {plugin_root}, zero CLAUDE_PLUGIN_ROOT, zero ToolSearch
  ```
- [ ] GREEN: Extend `replace_paths()` with:
  ```bash
  -e 's|{plugin_root}/shared/|~/.codex/shared/|g' \
  -e 's|{plugin_root}/rules/|~/.codex/rules/|g' \
  -e 's|{plugin_root}/skills/|~/.codex/skills/|g' \
  -e 's|{plugin_root}|~/.codex|g' \
  -e 's|CLAUDE_PLUGIN_ROOT|CODEX_HOME|g'
  ```
  Extend `strip_tool_names()` with:
  ```bash
  -e 's/ToolSearch(query="codesift", max_results=20)/Check if codesift MCP tools are available (mcp__codesift__list_repos)/g' \
  -e 's/ToolSearch(query="codesift"[^)]*)/Check if codesift MCP tools are available/g' \
  -e 's/ToolSearch(query="jcodemunch"[^)]*)/Check if jcodemunch MCP tools are available/g' \
  -e 's/ToolSearch(query="+playwright[^)]*)/Check if playwright MCP tools are available/g' \
  -e 's/`ToolSearch`/MCP tool check/g' \
  -e 's/ToolSearch/MCP tool check/g'
  ```
- [ ] Verify: `echo '{plugin_root}/rules/test.md' | bash -c 'source scripts/build-codex-skills.sh 2>/dev/null; replace_paths'` outputs `~/.codex/rules/test.md`
- [ ] Verify: `echo 'ToolSearch(query="codesift", max_results=20)' | bash -c 'source scripts/build-codex-skills.sh 2>/dev/null; strip_tool_names'` contains no "ToolSearch"
- [ ] Commit: `feat: extend replace_paths and strip_tool_names for zuvo tokens`

---

### Task 5: Rewrite map_model() and adapt generate_agent_toml()

**Files:** `scripts/build-codex-skills.sh`
**Complexity:** complex
**Dependencies:** Task 3
**Model routing:** Opus

- [ ] RED: The current `map_model opus` returns `gpt-5.4`. After rewrite it should return `gpt-5.3-codex`.
- [ ] GREEN: Rewrite `map_model()`:
  ```bash
  map_model() {
    local model="$1"
    case "$model" in
      haiku)   echo "gpt-5.4-mini" ;;
      sonnet)  echo "gpt-5.4" ;;
      opus)    echo "gpt-5.3-codex" ;;
      *)       echo "gpt-5.4" ;; # default to gpt-5.4
    esac
  }
  ```
  Adapt `generate_agent_toml()`:
  1. Change suffix from `"Spawned by /${skill}."` to `"Spawned by zuvo:${skill}."`
  2. Add `reasoning: true` detection:
     ```bash
     local is_reasoning
     is_reasoning=$(head -20 "$agent_md" | grep -c "^reasoning: true" || true)
     ```
  3. If `is_reasoning > 0` AND model was opus: use `gpt-5.4` (not gpt-5.3-codex) and add TOML field:
     ```bash
     if [ "$is_reasoning" -gt 0 ]; then
       codex_model="gpt-5.4"
       # After writing base TOML, append:
       echo 'model_reasoning_effort = "xhigh"' >> "$toml_path"
     fi
     ```
  4. Handle `implementer.md`'s non-standard model field (`"per-task: sonnet for standard complexity, opus for complex"`) -- extract first model name: `model=$(echo "$model" | awk '{print $1}')` before mapping
  5. Add explicit skip for `team-lead`:
     ```bash
     if [ "$agent_name" = "team-lead" ]; then return 0; fi
     ```
- [ ] Verify: Run TOML generation for a test agent with `reasoning: true` and confirm `model_reasoning_effort = "xhigh"` is present
- [ ] Verify: Run TOML generation for `team-lead.md` and confirm no TOML file is produced
- [ ] Commit: `feat: three-tier model mapping + reasoning effort + zuvo: prefix in TOML`

---

### Task 6: Adapt main pipeline and validation

**Files:** `scripts/build-codex-skills.sh`
**Complexity:** standard
**Dependencies:** Task 3, Task 4, Task 5
**Model routing:** Sonnet

- [ ] RED: Run `bash scripts/build-codex-skills.sh` -- it should fail or produce incomplete output because the paths aren't fully adapted yet
- [ ] GREEN: Fix remaining pipeline issues and add AUTO-DECISION injection:
  1. Skip `shared/` directory in the skill assembly loop (it's not a skill):
     ```bash
     [ "$skill" = "shared" ] && continue
     ```
  2. Add frontmatter completeness check before TOML loop:
     ```bash
     for agent_md in "$PLUGIN_DIR"/skills/*/agents/*.md; do
       agent_name=$(basename "$agent_md" .md)
       [ "$agent_name" = "team-lead" ] && continue
       has_desc=$(head -20 "$agent_md" | grep -c "^description:" || true)
       if [ "$has_desc" -eq 0 ]; then
         echo "ERROR: Missing description: frontmatter in $agent_md" >&2
         exit 1
       fi
     done
     ```
  3. Add AUTO-DECISION injection for brainstorm and design skills (spec D4):
     After `transform_skill_for_codex()`, add a post-processing step for brainstorm and design skills:
     ```bash
     if [ "$skill" = "brainstorm" ] || [ "$skill" = "design" ]; then
       sed -i '' \
         -e 's/Ask questions \*\*one at a time\*\*/Make decisions autonomously. Annotate each with \[AUTO-DECISION\]/g' \
         -e 's/Get a thumbs-up on each section/Annotate each decision with \[AUTO-DECISION\] and rationale/g' \
         -e '/## Phase 2: Design Dialogue/a\
\
> **Codex mode:** This skill runs autonomously. Every design decision is annotated with `[AUTO-DECISION]` including rationale and alternatives. Review the spec before running zuvo:plan.' \
         "$dst"
     fi
     ```
  4. Add validation checks:
     - `grep -r '{plugin_root}' "$DIST"` must return 0 matches
     - `grep -r 'ToolSearch' "$DIST"` must return 0 matches
     - `grep -r 'CLAUDE_PLUGIN_ROOT' "$DIST"` must return 0 matches
     - Check skill line counts, warn if >500
  4. Copy `.codex-plugin/plugin.json` and `.mcp.json` into `dist/codex/`
  5. Copy `skills/using-zuvo/agents/openai.yaml` into `dist/codex/skills/using-zuvo/agents/`
- [ ] Verify: `bash scripts/build-codex-skills.sh` completes with exit 0
- [ ] Verify: `ls dist/codex/skills/ | wc -l` = 33
- [ ] Verify: `ls dist/codex/agents/*.toml | wc -l` >= 12 (pipeline agents)
- [ ] Verify: `grep -r '{plugin_root}' dist/codex/ | wc -l` = 0
- [ ] Verify: `grep -r 'ToolSearch' dist/codex/ | wc -l` = 0
- [ ] Commit: `feat: complete Codex build pipeline with validation`

---

### Task 7: Update env-compat.md

**Files:** `shared/includes/env-compat.md`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

Documentation/config change. CRITICAL: additive-only edits -- preserve existing Claude Code content verbatim.

- [ ] Save SHA of current env-compat.md for regression check
- [ ] Add new section AFTER the existing "User Interaction" section:
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
- [ ] Verify: existing Claude Code table rows are unchanged (diff shows only additions)
- [ ] Verify: `grep -c 'Claude Code' shared/includes/env-compat.md` is same count as before edit
- [ ] Commit: `feat: add Codex CLI vs App distinction and interaction defaults to env-compat`

---

### Task 8: Update run-logger.md + create codex-agent-registry.md

**Files:** `shared/includes/run-logger.md`, `shared/includes/codex-agent-registry.md`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] Add Codex-aware path section to `shared/includes/run-logger.md` after "## How to Log":
  ```markdown
  ## Environment-Aware Log Path

  The log path depends on the execution environment:

  | Environment | Log path | Reason |
  |-------------|----------|--------|
  | Claude Code | `~/.zuvo/runs.log` | Persistent home directory |
  | Codex CLI (local) | `~/.zuvo/runs.log` | Real home directory |
  | Codex App (cloud) | `memory/zuvo-runs.log` | Home is ephemeral |
  | Write fails | Skip silently | Do not error on logging failure |

  Detection: if the environment variable `CODEX_WORKSPACE` is set or
  `~/.zuvo/` is not writable, use the project-local path.
  ```
- [ ] Create `shared/includes/codex-agent-registry.md`:
  ```markdown
  # Codex Agent Registry

  > Manifest of all TOML agent configs generated by `scripts/build-codex-skills.sh`.

  ## Generation Rules

  - One TOML per `agents/*.md` file that has `description:` frontmatter
  - `team-lead.md` is excluded (not a dispatched agent)
  - Naming: `<skill-prefix>-<agent-name>.toml`
  - Model mapping: haiku->gpt-5.4-mini, sonnet->gpt-5.4, opus->gpt-5.3-codex
  - Agents with `reasoning: true` get gpt-5.4 + model_reasoning_effort="xhigh"
  - Sandbox: agents with Write/Edit tools get "full", others get "read-only"
  - Description suffix: "Spawned by zuvo:<skill>."

  ## Thread Limit

  Codex caps at `max_threads: 6`. Current peak: 4 concurrent agents (build skill).
  Do not design skills that dispatch more than 6 agents in parallel.

  ## Depth Limit

  Codex default `max_depth: 1`. Zuvo uses depth-1 only (orchestrator -> subagents).
  Subagents must not spawn further subagents.
  ```
- [ ] Verify: `grep -q 'CODEX_WORKSPACE' shared/includes/run-logger.md`
- [ ] Verify: `test -f shared/includes/codex-agent-registry.md`
- [ ] Commit: `feat: add Codex path logic to run-logger + create agent registry`

---

### Task 9: Extend release.sh

**Files:** `scripts/release.sh`
**Complexity:** standard
**Dependencies:** Task 2 (.codex-plugin/plugin.json must exist), Task 6 (build script must work)
**Model routing:** Sonnet

- [ ] RED: `grep -q 'codex-plugin' scripts/release.sh` returns 1 (not found)
- [ ] GREEN: Add to `scripts/release.sh`:
  1. After the existing `sed -i '' "s/.../" .claude-plugin/plugin.json` line, add:
     ```bash
     sed -i '' "s/\"version\": \".*\"/\"version\": \"$NEW_VERSION\"/" .codex-plugin/plugin.json
     ```
  2. Before the `git commit` line, add the build step:
     ```bash
     echo "Building Codex distribution..."
     bash scripts/build-codex-skills.sh || { echo "Codex build failed! Aborting release."; exit 1; }
     ```
  3. The build output is in `dist/codex/` which is gitignored -- it does NOT get committed. The build step runs as a validation gate only.
- [ ] Verify: `grep -q 'codex-plugin' scripts/release.sh`
- [ ] Verify: `grep -q 'build-codex-skills' scripts/release.sh`
- [ ] Commit: `feat: extend release.sh with Codex manifest bump and build validation`

---

### Task 10: Full build + verify all acceptance criteria

**Files:** none (verification only)
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7, Task 8, Task 9
**Model routing:** Sonnet

Run the complete build and verify every spec acceptance criterion:

- [ ] `bash scripts/build-codex-skills.sh` exits 0
- [ ] AC1: `ls dist/codex/skills/ | wc -l` = 33; `ls dist/codex/agents/*.toml | wc -l` >= 12; `test -f dist/codex/.codex-plugin/plugin.json`
- [ ] AC2: Zero residual Claude-Code tool names: `grep -rE 'ToolSearch|TaskCreate|TaskUpdate|SendMessage|TeamCreate' dist/codex/ | wc -l` = 0; Zero `~/.claude/`: `grep -r '~/\.claude/' dist/codex/ | wc -l` = 0
- [ ] AC3: Every TOML has all 5 fields: `for f in dist/codex/agents/*.toml; do grep -q '^name' "$f" && grep -q '^description' "$f" && grep -q '^model' "$f" && grep -q '^sandbox_mode' "$f" && grep -q '^developer_instructions' "$f" || echo "FAIL: $f"; done`
- [ ] AC4: `grep -q 'allow_implicit_invocation: true' dist/codex/skills/using-zuvo/agents/openai.yaml` (or verify TOML fallback if OQ1 rejected)
- [ ] AC5: `grep -q 'AUTO-DECISION' dist/codex/skills/brainstorm/SKILL.md` — must pass unconditionally (Task 6 implements injection)
- [ ] AC6: `grep -q 'Codex CLI' shared/includes/env-compat.md` and `grep -q 'Codex App' shared/includes/env-compat.md`
- [ ] AC7: `python3 -m json.tool .codex-plugin/plugin.json > /dev/null` and `grep -q '"skills"' .codex-plugin/plugin.json`
- [ ] AC8: `grep -q 'codex-plugin' scripts/release.sh`
- [ ] AC9: `grep -r 'mcp__codesift' dist/codex/skills/ | head -3` shows direct MCP references exist
- [ ] AC10: `grep -r 'ToolSearch' dist/codex/ | wc -l` = 0
- [ ] AC11: Model mapping: `grep 'model = "gpt-5.4-mini"' dist/codex/agents/*.toml | wc -l` >= 1; `grep 'model = "gpt-5.3-codex"' dist/codex/agents/*.toml | wc -l` >= 1
- [ ] AC12: Claude Code unchanged: `git diff skills/ | wc -l` shows only frontmatter additions, no SKILL.md content changes
- [ ] AC13: `grep -q 'dist/' .gitignore`
- [ ] AC14: `test -f .codex-plugin/plugin.json` (committed at root, not in dist)
- [ ] Deliverable checks (Task 7+8 outputs):
  - `grep -q 'CODEX_WORKSPACE' shared/includes/run-logger.md`
  - `grep -q 'max_threads' shared/includes/codex-agent-registry.md`
  - `grep -q 'max_depth' shared/includes/codex-agent-registry.md`
- [ ] Commit: (no commit -- verification only)

---

### Task 11: Documentation updates

**Files:** `README.md`, `docs/getting-started.md`, `docs/configuration.md`
**Complexity:** standard
**Dependencies:** Task 10 (verify build works first)
**Model routing:** Sonnet

Documentation change (TDD protocol: does NOT apply).

- [ ] Add Codex section to `README.md` after the existing Install section:
  ```markdown
  ### Codex (experimental)

  Build the Codex distribution:

  ```bash
  bash scripts/build-codex-skills.sh
  ```

  Then copy to your Codex skills directory:

  ```bash
  cp -r dist/codex/skills/* ~/.codex/skills/
  cp dist/codex/agents/*.toml ~/.codex/agents/
  ```

  Optional: add CodeSift MCP to your `~/.codex/config.toml`:

  ```toml
  [mcp_servers.codesift]
  command = "npx"
  args = ["-y", "codesift-mcp"]
  ```
  ```
- [ ] Add Codex installation section to `docs/getting-started.md`
- [ ] Update `docs/configuration.md`:
  - Add `.codex-plugin/plugin.json` to plugin structure tree
  - Add `.mcp.json` to structure tree
  - Add `codex-agent-registry.md` to shared includes table
  - Update `run-logger.md` description in shared includes table
- [ ] Verify: all links in docs are valid (no broken references)
- [ ] Commit: `docs: add Codex installation and configuration instructions`

---

### Task 12: Update spec status to Approved

**Files:** `docs/specs/2026-03-27-codex-compatibility-spec.md`
**Complexity:** standard
**Dependencies:** Task 10 (full verification must pass before approving spec)
**Model routing:** Sonnet

- [ ] Change `> **Status:** Draft` to `> **Status:** Approved`
- [ ] Commit: `docs: approve Codex compatibility spec`
