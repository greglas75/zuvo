# Implementation Plan: Antigravity Build Target

**Spec:** docs/specs/2026-04-08-antigravity-build-target-spec.md
**spec_id:** 2026-04-08-antigravity-build-1215
**plan_revision:** 1
**status:** Reviewed
**Created:** 2026-04-08
**Tasks:** 8
**Estimated complexity:** 6 standard, 2 complex

## Architecture Summary

The build pipeline follows a proven 3-stage pattern per platform:
1. `build-<platform>-skills.sh` transforms source → `dist/<platform>/`
2. `install_<platform>()` in `install.sh` copies dist → `~/.<platform>/`
3. `dev-push.sh` orchestrates git push + install for all platforms

Antigravity is the 4th platform. Install target: `~/.gemini/antigravity/skills/`. Template: `build-cursor-skills.sh` (simplest existing build — no TOML, no flat renaming). New functions needed: `replace_model_refs()`, `replace_config_refs()`. Agent subdirectories preserved natively (unlike Cursor which flattens).

Key files touched:
- NEW: `scripts/build-antigravity-skills.sh`
- EDIT: `scripts/install.sh` (~20 lines)
- EDIT: `scripts/quick-install.sh` (banner text)
- EDIT: `shared/includes/env-compat.md` (4th column in tables)
- EDIT: `shared/includes/run-logger.md` (Antigravity detection)
- EDIT: `shared/includes/platform-detection.md` (non-interactive list)

## Technical Decisions

- **Template:** Clone `build-cursor-skills.sh`, then diverge on model mapping, config refs, and agent handling
- **No new dependencies** — pure bash, matching existing scripts
- **Shared functions** (`normalize_unicode`, `get_skill_prefix`) are copy-pasted per build script (existing pattern — CQ14 debt acknowledged but consistent with Codex/Cursor precedent)
- **Model mapping:** `sonnet→gemini-3.1-pro-low`, `opus→gemini-3.1-pro-high`, `haiku→gemini-3-flash`
- **Validation:** recursive grep across `dist/antigravity/` including `skills/*/agents/` subdirs

## Quality Strategy

- **No test framework** — this is a markdown + bash project. "Tests" = the build script's `validate_output()` function
- **TDD adapted:** RED = add validation check that would catch missing transforms; GREEN = implement the transform; Verify = run full build
- **Risk areas:** (1) `replace_config_refs()` scope — must NOT touch shared includes, (2) model name replacement in prose vs frontmatter, (3) spawn block parser adaptation from Cursor
- **CQ gates:** CQ14 (duplication with Cursor build) accepted — consistent with project pattern. CQ25 (pattern consistency) is the primary quality signal.

## Task Breakdown

### Task 1: Scaffold build-antigravity-skills.sh with skeleton and validate_output()

**Files:** `scripts/build-antigravity-skills.sh` (new)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: Create the script with shebang, `set -euo pipefail`, variables (`DIST="dist/antigravity"`, `PLATFORM="antigravity"`), empty `main()` function, and a `validate_output()` function that greps for residual Claude tokens (`CLAUDE_PLUGIN_ROOT`, `~/.claude/`, `model: sonnet`, `model: haiku`, `model: opus`, `model: "sonnet"`, `model: "haiku"`, `model: "opus"`, `{plugin_root}`, `ToolSearch`, `AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode`, `Claude Code`). Running the script should fail because no skills are copied yet (empty dist).
- [ ] GREEN: Add `mkdir -p "$DIST"` and a basic skill copy loop that copies raw SKILL.md files to `dist/antigravity/skills/`. Running validate_output should FAIL (residual tokens present) — this confirms the validator works.
- [ ] Verify: `bash scripts/build-antigravity-skills.sh 2>&1 | tail -5`
  Expected: Non-zero exit with validation error count > 0
- [ ] Acceptance: AC1 (script exists), AC5 (validation catches residuals)
- [ ] Commit: `scaffold build-antigravity-skills.sh with validation-first approach`

### Task 2: Implement replace_paths() and replace_config_refs()

**Files:** `scripts/build-antigravity-skills.sh` (edit)
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep

- [ ] RED: After Task 1, validate_output fails on `~/.claude/`, `CLAUDE_PLUGIN_ROOT`, `{plugin_root}`, and `Claude Code` residuals.
- [ ] GREEN: Implement `replace_paths()`: `~/.claude/` → `~/.gemini/antigravity/`, `CLAUDE_PLUGIN_ROOT` → `GEMINI_HOME`, `{plugin_root}` → `~/.gemini/antigravity/` (with subdirectory variants). Implement `replace_config_refs()`: `CLAUDE.md` → `GEMINI.md`, and `Claude Code` → `Antigravity` ONLY in skill body text (not shared includes — use path guard: `if [[ "$file" == *"/skills/"* && "$file" != *"/shared/"* ]]`). Wire both into the skill transform loop.
- [ ] Verify: `bash scripts/build-antigravity-skills.sh 2>&1 | grep -c "CLAUDE_PLUGIN_ROOT\|~/\.claude/\|{plugin_root}\|Claude Code"`
  Expected: 0 (no residuals for these tokens)
- [ ] Acceptance: AC5 (no residual Claude tokens)
- [ ] Commit: `add path and config reference transforms for Antigravity build`

### Task 3: Implement replace_model_refs()

**Files:** `scripts/build-antigravity-skills.sh` (edit)
**Complexity:** complex
**Dependencies:** Task 2
**Execution routing:** deep

- [ ] RED: validate_output still fails on `model: sonnet`, `model: haiku`, `model: opus` (and quoted variants) in frontmatter. Prose mentions of "Sonnet", "Opus", "Haiku" as model tiers still present.
- [ ] GREEN: Implement `replace_model_refs()` operating on:
  - YAML frontmatter: `model: sonnet` → `model: gemini-3.1-pro-low`, `model: opus` → `model: gemini-3.1-pro-high`, `model: haiku` → `model: gemini-3-flash`
  - Quoted dispatch: `model: "sonnet"` → `model: "gemini-3.1-pro-low"` (etc.)
  - Prose tables: "Sonnet" → "Gemini 3.1 Pro Low", "Opus" → "Gemini 3.1 Pro High", "Haiku" → "Gemini 3 Flash"
  - Exclusion: do NOT replace inside adversarial-review context (provider names). Use file-scope guard: skip files matching `*adversarial*`.
- [ ] Verify: `bash scripts/build-antigravity-skills.sh 2>&1 | grep -c "model: sonnet\|model: haiku\|model: opus"`
  Expected: 0
- [ ] Acceptance: AC7 (model mapping correct), AC8 (prose model names replaced)
- [ ] Commit: `add Gemini model mapping for Antigravity build (3-tier: flash/low/high)`

### Task 4: Implement strip_tool_names() and replace_spawn_blocks()

**Files:** `scripts/build-antigravity-skills.sh` (edit)
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: validate_output fails on `ToolSearch`, `AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode` residuals.
- [ ] GREEN: Implement `strip_tool_names()`: replace `ToolSearch(...)` → "Check if MCP tools are available", replace `AskUserQuestion` blocks → `[AUTO-DECISION: proceed with safest default]`, remove `EnterPlanMode`/`ExitPlanMode`, replace `TaskCreate`/`TaskUpdate` → inline `STEP:` text. Implement `replace_spawn_blocks()` using the awk parser pattern from Cursor build (examine `build-cursor-skills.sh` for the actual spawn block replacement code and adapt).
- [ ] Verify: `bash scripts/build-antigravity-skills.sh 2>&1 | grep -c "ToolSearch\|AskUserQuestion\|EnterPlanMode\|ExitPlanMode"`
  Expected: 0
- [ ] Acceptance: AC5 (no residual tool names), AC10 (spawn blocks replaced)
- [ ] Commit: `add tool name replacement and spawn block transforms for Antigravity`

### Task 5: Implement adapt_agent_for_antigravity() and normalize_unicode()

**Files:** `scripts/build-antigravity-skills.sh` (edit)
**Complexity:** standard
**Dependencies:** Task 3
**Execution routing:** default

- [ ] RED: Agent .md files in `dist/antigravity/skills/*/agents/` still have `tools:` lists and Claude model names in frontmatter.
- [ ] GREEN: Implement `adapt_agent_for_antigravity()`: for each agent .md file in `skills/*/agents/`, strip `tools:` block from YAML frontmatter (including multi-line list), map model name using same mapping as `replace_model_refs()`. Copy agents into `dist/antigravity/skills/<name>/agents/` subdirectories (NOT flat). Implement `normalize_unicode()` — copy from Cursor build verbatim.
- [ ] Verify: `grep -r "tools:" dist/antigravity/skills/*/agents/*.md 2>/dev/null | wc -l && grep -r "model: sonnet\|model: haiku\|model: opus" dist/antigravity/skills/*/agents/*.md 2>/dev/null | wc -l`
  Expected: 0 and 0
- [ ] Acceptance: AC9 (agent frontmatter transformed)
- [ ] Commit: `add agent frontmatter adaptation and unicode normalization for Antigravity`

### Task 6: Wire install_antigravity() into install.sh

**Files:** `scripts/install.sh` (edit), `scripts/quick-install.sh` (edit)
**Complexity:** standard
**Dependencies:** Task 1 (script must exist)
**Execution routing:** default

- [ ] RED: `./scripts/install.sh antigravity` fails with "Usage:" error (unrecognized target).
- [ ] GREEN: Add `install_antigravity()` function to `install.sh`:
  1. Guard: `if [[ ! -d "$HOME/.gemini/antigravity" ]]; then warn "Antigravity not found"; return 0; fi`
  2. Run `bash "$SCRIPT_DIR/build-antigravity-skills.sh"`
  3. `rm -rf ~/.gemini/antigravity/skills/ ~/.gemini/antigravity/shared/ ~/.gemini/antigravity/rules/ ~/.gemini/antigravity/scripts/` (clean old symlinks + stale files)
  4. `cp -r dist/antigravity/skills/ ~/.gemini/antigravity/skills/`
  5. `cp -r dist/antigravity/shared/ ~/.gemini/antigravity/shared/`
  6. `cp -r dist/antigravity/rules/ ~/.gemini/antigravity/rules/`
  7. `cp -r dist/antigravity/scripts/ ~/.gemini/antigravity/scripts/`
  Update case switch (~line 362): add `antigravity)` branch, update `both|all)` to include `install_antigravity`, update `Usage:` string.
  Update `quick-install.sh` banner: add "Antigravity" to restart message.
- [ ] Verify: `./scripts/install.sh antigravity 2>&1 | head -10`
  Expected: Build output followed by copy confirmation (or "Antigravity not found" warning if not installed)
- [ ] Acceptance: AC2 (install copies to correct path), AC3 (all target includes Antigravity), AC11 (dead symlinks replaced), AC12 (case switch updated)
- [ ] Commit: `wire Antigravity into install.sh and quick-install.sh`

### Task 7: Update env-compat.md and shared includes

**Files:** `shared/includes/env-compat.md` (edit), `shared/includes/run-logger.md` (edit), `shared/includes/platform-detection.md` (edit)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: `env-compat.md` Execution Models table has 3 columns (Claude Code, Codex, Cursor) but no Antigravity.
- [ ] GREEN:
  - `env-compat.md`: Add Antigravity as 4th column in Execution Models table, Path Resolution table, Agent Dispatch Patterns section, Progress Tracking section, User Interaction section. Verify existing Interaction Defaults entry (line 155) is consistent.
  - `run-logger.md`: Add Antigravity detection heuristic (`$GEMINI_WORKSPACE` or similar) to log path logic.
  - `platform-detection.md`: Add Antigravity to non-interactive environment lists alongside Codex and Cursor.
- [ ] Verify: `grep -c "Antigravity" shared/includes/env-compat.md`
  Expected: 10+ (present in all tables)
- [ ] Acceptance: AC6 (complete Antigravity column in every table)
- [ ] Commit: `add Antigravity to env-compat.md, run-logger.md, and platform-detection.md`

### Task 8: Copy shared includes, rules, scripts to dist and final validation

**Files:** `scripts/build-antigravity-skills.sh` (edit)
**Complexity:** standard
**Dependencies:** Task 2, Task 4, Task 5
**Execution routing:** default

- [ ] RED: `dist/antigravity/` missing `shared/`, `rules/`, `scripts/` directories. Full build validation should pass but dist is incomplete.
- [ ] GREEN: Add to build script: copy `shared/includes/*.md` → `dist/antigravity/shared/includes/`, copy `rules/*.md` → `dist/antigravity/rules/`, copy `scripts/adversarial-review.sh` → `dist/antigravity/scripts/`. Apply `replace_paths()` and `replace_config_refs()` to copied shared includes (but NOT `replace_config_refs()`'s `Claude Code → Antigravity` substitution — shared includes are multi-platform). Add overlay check: `if [ -f "$skill_dir/antigravity/SKILL.antigravity.md" ]` copy verbatim (skip transforms, skip validation for overlayed files). Final: wire `main()` to call all functions in order, run `validate_output()` at end.
- [ ] Verify: `bash scripts/build-antigravity-skills.sh && echo "BUILD OK" && ls dist/antigravity/{shared,rules,scripts} | head -10`
  Expected: "BUILD OK" with zero validation errors, listing of shared/rules/scripts files
- [ ] Acceptance: AC1 (zero validation errors), AC4 (all skills build), AC13 (ship/deploy push-skip list), AC14 (adversarial-review.sh copied and paths updated)
- [ ] Commit: `complete Antigravity build with shared includes, rules, scripts, and overlay support`
