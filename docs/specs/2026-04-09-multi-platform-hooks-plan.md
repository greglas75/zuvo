# Implementation Plan: Multi-Platform Hook Support

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**plan_revision:** 2
**status:** Draft
**Created:** 2026-04-09
**Tasks:** 7 (T1-T5 + T6a + T6b; validation folded into T4/T5)
**Estimated complexity:** all standard (shell scripts + JSON config, no code architecture)

## Architecture Summary

zuvo currently has 3 hooks for Claude Code only:
1. **SessionStart** — injects skill router into session context
2. **PreToolUse(Bash)** — blocks git push/PR without prior zuvo:review
3. **PostToolUse(Skill)** — enforces adversarial review after code-producing skills

This plan ports hooks 1 and 2 to **Codex CLI** and **Gemini CLI (Antigravity)**. Hook 3 (PostToolUse/Skill) is skipped on both platforms — neither has a "Skill" tool concept.

### Platform mapping:

| Hook | Claude Code | Codex CLI | Gemini CLI |
|------|-------------|-----------|------------|
| SessionStart | `SessionStart` | `SessionStart` | `SessionStart` |
| Pre-push gate | `PreToolUse` + `Bash` | `PreToolUse` + `Bash` (TBC) | `BeforeTool` + `run_shell_command` |
| Adversarial check | `PostToolUse` + `Skill` | SKIP | SKIP |

### Reference: Figma plugin (Codex)
- Location: `~/.codex/.tmp/plugins/plugins/figma/`
- Uses `"hooks": "./hooks.json"` in plugin.json
- hooks.json format identical to Claude Code
- Relative paths: `"./scripts/post_write_figma_parity_check.sh"`

## Technical Decisions

1. **Codex**: Same hooks.json format as Claude Code. New source file `hooks/hooks.codex.json`. Referenced from `.codex-plugin/plugin.json` via `"hooks": "./hooks.json"`. Build script copies + applies path replacement.

2. **Codex plugin cache**: Codex only discovers hooks.json from formally-installed plugins in `~/.codex/.tmp/plugins/plugins/<name>/`. The `install_codex()` function must create `~/.codex/.tmp/plugins/plugins/zuvo/` with hooks.json, plugin.json, and hook scripts — in addition to the existing flat copy to `~/.codex/skills/`. Reference: Figma plugin at `~/.codex/.tmp/plugins/plugins/figma/`.

3. **Gemini**: Different event names (`BeforeTool`, not `PreToolUse`) and tool names (`run_shell_command`, not `Bash`). New source file `hooks/hooks.antigravity.json`. Install script merges into `~/.gemini/settings.json` via python3 (idempotent).

4. **Hook scripts are shared**: `session-start` and `pre-push-gate.sh` are platform-agnostic. `session-start` already self-locates via `dirname $0`. Only change: add Codex/Gemini branches for output format detection.

5. **Relative paths in Codex hooks.json**: Codex resolves hook commands relative to plugin root (confirmed by Figma reference). Use `./hooks/pre-push-gate.sh` pattern.

6. **Absolute paths in Gemini hooks.json**: Gemini hooks are merged into user-level `~/.gemini/settings.json`, not a plugin directory. Must use absolute paths like `$HOME/.gemini/antigravity/hooks/pre-push-gate.sh`.

7. **PostToolUse(Skill) explicitly skipped**: Both Codex and Gemini lack a "Skill" tool. Enforcement on those platforms remains via skill-chaining.

## Quality Strategy

- **No TDD**: This is configuration + shell scripting. TDD protocol exempts config changes.
- **Verification**: Each task has a shell command to verify the output (JSON validation, file existence, grep checks).
- **Build validation**: Both build scripts get new validation checks for hook artifacts.
- **Idempotency**: Gemini settings.json merge must be safe to run multiple times.
- **Risk**: stdin format on Codex/Gemini is an empirical unknown — pre-push-gate uses substring glob matching which is format-agnostic (works with JSON envelope, raw string, or nested objects).

## Task Breakdown

### Task 1: Create Codex hook config and update plugin manifest
**Files:** `hooks/hooks.codex.json` (new), `.codex-plugin/plugin.json` (modify)
**Complexity:** standard
**Dependencies:** none

- [ ] RED: Verify no Codex hook config exists yet
  `test ! -f hooks/hooks.codex.json && echo "MISSING"`
  Expected: MISSING
- [ ] GREEN: Create `hooks/hooks.codex.json` with SessionStart + PreToolUse hooks
  - SessionStart: matcher `startup|clear|compact`, command `./hooks/session-start`
  - PreToolUse: matcher `Bash`, command `bash ./hooks/pre-push-gate.sh`
  - Use relative paths (Codex resolves relative to plugin root, confirmed by Figma)
  - Add `"hooks": "./hooks.json"` to `.codex-plugin/plugin.json`
- [ ] Verify: `python3 -m json.tool hooks/hooks.codex.json > /dev/null && echo OK`
  Expected: OK
- [ ] Verify: `grep '"hooks"' .codex-plugin/plugin.json`
  Expected: line containing `"hooks": "./hooks.json"`
- [ ] Commit: `add Codex hook config with SessionStart + PreToolUse gates`

### Task 2: Create Gemini hook config
**Files:** `hooks/hooks.antigravity.json` (new)
**Complexity:** standard
**Dependencies:** none

- [ ] RED: Verify no Gemini hook config exists yet
  `test ! -f hooks/hooks.antigravity.json && echo "MISSING"`
  Expected: MISSING
- [ ] GREEN: Create `hooks/hooks.antigravity.json` with SessionStart + BeforeTool hooks
  - SessionStart: same structure as Codex but with absolute path `$HOME/.gemini/antigravity/hooks/session-start`
  - BeforeTool (not PreToolUse): matcher `run_shell_command` (not Bash), command with absolute path
  - Gemini reads hooks from `~/.gemini/settings.json`, not a plugin hooks.json — this file is a merge template
- [ ] Verify: `python3 -m json.tool hooks/hooks.antigravity.json > /dev/null && echo OK`
  Expected: OK
- [ ] Verify: `grep -c 'BeforeTool\|run_shell_command' hooks/hooks.antigravity.json`
  Expected: lines containing Gemini-specific event/tool names
- [ ] Commit: `add Gemini hook config template with SessionStart + BeforeTool gates`

### Task 3: Extend session-start with Codex and Gemini platform detection
**Files:** `hooks/session-start` (modify), `hooks/pre-push-gate.sh` (modify)
**Complexity:** standard
**Dependencies:** none

- [ ] RED: Verify session-start has no Codex/Gemini branches
  `grep -c 'CODEX\|GEMINI' hooks/session-start`
  Expected: 0
- [ ] GREEN: Add platform detection branches to session-start
  - Add `elif [ -n "${CODEX_PLUGIN_ROOT:-}" ]` branch — emit `hookSpecificOutput` format (same as CC, Codex uses identical hook output contract)
  - Add `elif [ -n "${GEMINI_PROJECT_DIR:-}" ]` branch — emit Gemini-compatible JSON format
  - Keep existing Claude Code and Cursor branches unchanged
  - Resolve SKILL.md path from `dirname $0` (already works — script self-locates)
  - Order: Cursor → Codex → Claude Code → Gemini → fallback
  - Note: `CODEX_PLUGIN_ROOT` is set by Codex when running hooks from formally-installed plugins. For manual installs, the fallback branch handles it.
  - Update stale comment in `hooks/pre-push-gate.sh` line 5-6: remove "hooks don't exist on Codex/Cursor/Antigravity" — they now do on Codex and Gemini
- [ ] Verify: `grep -c 'CODEX_PLUGIN_ROOT\|GEMINI' hooks/session-start`
  Expected: >= 2 (at least one reference per platform)
- [ ] Verify: `bash hooks/session-start 2>&1 | head -1`
  Expected: valid JSON output (uses fallback branch when no env vars set)
- [ ] Commit: `extend session-start hook with Codex and Gemini platform detection`

### Task 4: Add hook generation + validation to build-codex-skills.sh
**Files:** `scripts/build-codex-skills.sh` (modify)
**Complexity:** standard
**Dependencies:** Task 1, Task 3 (session-start must be modified before copying)

- [ ] RED: Verify build script produces no hook artifacts
  `bash scripts/build-codex-skills.sh && test ! -f dist/codex/hooks/pre-push-gate.sh && echo "NO HOOKS"`
  Expected: NO HOOKS
- [ ] GREEN: Add hook generation section to build-codex-skills.sh
  - After section 4 (Copy manifests), add section 4b: Hooks
  - Copy `hooks/hooks.codex.json` to `dist/codex/hooks.json` (applying `replace_paths()`)
  - Copy `hooks/pre-push-gate.sh` and `hooks/session-start` to `dist/codex/hooks/` (applying `replace_paths()`)
  - Copy `hooks/run-hook.cmd` to `dist/codex/hooks/` (no path replacement needed)
  - chmod +x the hook scripts
  - Update `plugin.json` in dist to reference hooks: ensure `"hooks": "./hooks.json"` is present
  - Add validation checks to section 5 (Validation):
    - Verify `dist/codex/hooks.json` exists and is valid JSON
    - Verify `dist/codex/hooks/pre-push-gate.sh` exists and is executable
    - Verify `dist/codex/hooks/session-start` exists
    - Verify hooks.json does NOT contain `CLAUDE_PLUGIN_ROOT` (path leak)
    - Verify hooks.json does NOT contain `~/.claude/` paths
- [ ] Verify: `bash scripts/build-codex-skills.sh && python3 -m json.tool dist/codex/hooks.json > /dev/null && echo OK`
  Expected: OK
- [ ] Verify: `test -x dist/codex/hooks/pre-push-gate.sh && test -f dist/codex/hooks/session-start && echo OK`
  Expected: OK
- [ ] Commit: `add hook generation and validation to Codex build pipeline`

### Task 5: Add hook generation + validation to build-antigravity-skills.sh
**Files:** `scripts/build-antigravity-skills.sh` (modify)
**Complexity:** standard
**Dependencies:** Task 2, Task 3 (session-start must be modified before copying)

- [ ] RED: Verify Antigravity build produces no hook artifacts
  `bash scripts/build-antigravity-skills.sh && test ! -f dist/antigravity/hooks/pre-push-gate.sh && echo "NO HOOKS"`
  Expected: NO HOOKS
- [ ] GREEN: Add hook generation section to build-antigravity-skills.sh
  - After section 1 (Normalize rules + shared includes), add section 1b: Hooks
  - Copy `hooks/hooks.antigravity.json` to `dist/antigravity/hooks.json` (applying `replace_paths()`)
  - Copy `hooks/pre-push-gate.sh` and `hooks/session-start` to `dist/antigravity/hooks/` (applying `replace_paths()`)
  - chmod +x the hook scripts
  - Add validation checks to section 3 (Validation):
    - Verify `dist/antigravity/hooks.json` exists and is valid JSON
    - Verify `dist/antigravity/hooks/pre-push-gate.sh` exists and is executable
    - Verify hooks.json contains `BeforeTool` and `run_shell_command` (Gemini names)
    - Verify hooks.json does NOT contain `PreToolUse` or `"Bash"` (Claude Code names)
    - Verify hooks.json does NOT contain `CLAUDE_PLUGIN_ROOT`
- [ ] Verify: `bash scripts/build-antigravity-skills.sh && python3 -m json.tool dist/antigravity/hooks.json > /dev/null && echo OK`
  Expected: OK
- [ ] Verify: `test -x dist/antigravity/hooks/pre-push-gate.sh && test -f dist/antigravity/hooks/session-start && echo OK`
  Expected: OK
- [ ] Commit: `add hook generation and validation to Antigravity build pipeline`

### Task 6a: Add Codex hook installation to install.sh
**Files:** `scripts/install.sh` (modify)
**Complexity:** standard
**Dependencies:** Task 4

- [ ] RED: Verify install_codex has no hook step
  `grep -c 'plugin.*cache\|\.tmp/plugins' scripts/install.sh`
  Expected: 0
- [ ] GREEN: Add Step 8 to `install_codex()`: Install hooks to Codex plugin cache
  - Create `$HOME/.codex/.tmp/plugins/plugins/zuvo/` if it doesn't exist
  - Copy `dist/codex/hooks.json` to the plugin root
  - Copy `dist/codex/.codex-plugin/plugin.json` to plugin root as `.codex-plugin/plugin.json`
  - Create `hooks/` subdirectory in plugin root
  - Copy `dist/codex/hooks/*` (pre-push-gate.sh, session-start, run-hook.cmd) to plugin root `hooks/`
  - chmod +x hook scripts
  - Also copy skills to plugin root `skills/` (so plugin is self-contained)
  - Note: Codex only discovers hooks.json from `~/.codex/.tmp/plugins/plugins/`. The flat install to `~/.codex/skills/` continues for backward compatibility.
  - Print confirmation: `ok "Hooks installed to plugin cache"`
- [ ] Verify: `bash scripts/install.sh codex 2>&1 | grep -i hook`
  Expected: confirmation line about hooks installed
- [ ] Verify: `test -f "$HOME/.codex/.tmp/plugins/plugins/zuvo/hooks.json" && echo OK`
  Expected: OK
- [ ] Commit: `add Codex hook installation via plugin cache`

### Task 6b: Add Gemini hook installation to install.sh
**Files:** `scripts/install.sh` (modify)
**Complexity:** standard
**Dependencies:** Task 5

- [ ] RED: Verify install_antigravity has no hook step
  `grep -c 'settings\.json' scripts/install.sh`
  Expected: 0
- [ ] GREEN: Add Step 7 to `install_antigravity()`: Copy hooks + merge settings.json
  - `mkdir -p "$HOME/.gemini/antigravity/hooks"`
  - Copy `dist/antigravity/hooks/*` to `$HOME/.gemini/antigravity/hooks/`
  - chmod +x hook scripts
  - Use python3 to merge hook entries from `dist/antigravity/hooks.json` into `~/.gemini/settings.json`
  - Merge logic (python3):
    - Read existing settings.json (or create empty `{}` if missing)
    - Handle malformed JSON: try/except, warn + skip merge, don't corrupt
    - For each event key in hooks template (SessionStart, BeforeTool):
      - Check if a zuvo hook already exists (match on `pre-push-gate` or `session-start` in command path)
      - If not present: add hook entry to the event array
      - If already present: update in place (idempotent)
    - Write back atomically (write to temp, then rename)
  - Print confirmation: `ok "Hooks installed + settings.json updated"`
- [ ] Verify: `bash scripts/install.sh antigravity 2>&1 | grep -i hook`
  Expected: confirmation line about hooks + settings.json
- [ ] Verify: Functional idempotency test —
  ```
  cp ~/.gemini/settings.json /tmp/settings-before.json 2>/dev/null
  bash scripts/install.sh antigravity
  bash scripts/install.sh antigravity
  python3 -c "import json; d=json.load(open('$HOME/.gemini/settings.json')); hooks=str(d.get('hooks',{})); assert hooks.count('pre-push-gate') <= 2; print('IDEMPOTENT')"
  ```
  Expected: IDEMPOTENT (no duplicate entries after double install)
- [ ] Commit: `add Gemini hook installation with idempotent settings.json merge`
