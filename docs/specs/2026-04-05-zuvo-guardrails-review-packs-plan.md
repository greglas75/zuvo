# Implementation Plan: Zuvo Guardrails and Review Packs

**Spec:** `docs/specs/2026-04-05-zuvo-guardrails-review-packs-spec.md`
**spec_id:** `2026-04-05-zuvo-guardrails-review-packs-2144`
**plan_revision:** 1
**status:** Reviewed
**Created:** 2026-04-05
**Tasks:** 9
**Estimated complexity:** 3 complex, 6 standard

## Architecture Summary

The feature lands in three layers that already exist in the plugin:

1. **Policy contract layer** in `shared/includes/` plus example artifacts under `docs/examples/`.
2. **Runtime enforcement layer** in `hooks/` for Claude Code only.
3. **Skill and product surface layer** in `skills/`, docs, manifests, and website metadata.

Existing repo structure changes the implementation approach in two important ways:

- `hooks/run-hook.cmd` is already a generic named-hook launcher, so it does not need a new dispatch mechanism.
- `scripts/install.sh` currently syncs skills, shared includes, rules, and docs for Claude, but not `hooks/`. That must be fixed early or the new runtime hooks will not be testable in local Claude installs.

Dependency direction:

- `shared/includes/policy-runtime.md` defines the canonical policy schema and runtime decision contract.
- `skills/guardrails/SKILL.md` authors `.zuvo/policies/*.yaml` artifacts in that canonical format.
- `hooks/policy-runtime-lib.sh` evaluates those artifacts and is called by `hooks/pre-tool-use`, `hooks/user-prompt-submit`, and `hooks/stop`.
- `hooks/hooks.json` wires those event adapters into Claude Code.
- `skills/review/SKILL.md` extends the existing review core with `--focus` packs; adjacent skills and docs reference those packs rather than creating a second review engine.
- Docs, manifests, and website metadata must move from 39 to 40 skills and describe platform-specific enforcement correctly.

## Technical Decisions

- **No new runtime dependencies.** The implementation stays bash/markdown/shell-only, matching the current repo. No npm, Python, or third-party parser dependency is introduced.
- **Canonical YAML subset.** `.zuvo/policies/*.yaml` stays YAML as required by the spec, but `zuvo:guardrails` writes a constrained canonical layout that the shell runtime can parse deterministically.
- **Single evaluator, thin hook adapters.** Event-specific scripts normalize Claude hook input and delegate evaluation to one shared runtime library to avoid duplicate precedence logic.
- **Claude-only hard enforcement.** Codex and Cursor stay advisory. They can create, read, explain, and simulate policies, but not block runtime actions.
- **Review packs stay inside `zuvo:review`.** `errors`, `tests`, `comments`, `types`, and `simplify` are implemented as a `--focus` mode over the current tiering/reporting engine. Thin aliases are deferred.
- **Website sync is mandatory.** The repo hardcodes skill counts and slug allow-lists in multiple files, including `scripts/validate-skill-pages.sh`, so the new skill must be reflected everywhere in the same implementation pass.

## Quality Strategy

- **Test approach:** this repo does not have a formal automated test suite today, so verification relies on shell smoke checks, hook JSON fixture runs, build script smoke runs, and website validation. That is acceptable for markdown/configuration tasks and is the safest practical strategy for this codebase.
- **Highest-risk surfaces:** shell parsing of canonical YAML, Claude hook input/output contract handling, and documentation/count drift across manifests and website metadata.
- **CQ gates to watch:** CQ3 for validating hook input and policy fields, CQ5 for rejecting secret-like content in policy messages, CQ8 for fail-safe hook behavior on malformed input, CQ14 for keeping evaluation logic centralized, CQ19 for the runtime decision JSON contract, CQ25 for following existing skill/include patterns.
- **Verification rule:** every runtime task must prove both syntax validity (`bash -n`) and at least one fixture-driven behavior check. Every metadata/docs task must prove consistency with grep or validator scripts, not just file existence.

## Task Breakdown

### Task 1: Define the canonical policy runtime contract and examples

**Files:** `shared/includes/policy-runtime.md`, `docs/examples/guardrails/block-dangerous-bash.yaml`, `docs/examples/guardrails/warn-large-edit.yaml`
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: Confirm the contract include and example policy files do not exist yet: `test -f shared/includes/policy-runtime.md || echo MISSING` and `find docs/examples/guardrails -maxdepth 1 -name '*.yaml' 2>/dev/null | wc -l | tr -d ' '`
- [ ] GREEN: Create `shared/includes/policy-runtime.md` as the single source of truth for the clean-room schema, canonical YAML layout, precedence (`block > require_confirmation > warn`), advisory downgrade rules, host capability rules, evidence states, and secret-redaction constraints. Create two example policies that exercise Bash blocking and edit warnings in the exact format the runtime will parse.
- [ ] Verify: `grep -q "allow | warn | block | require_confirmation" shared/includes/policy-runtime.md && grep -q "block > require_confirmation > warn" shared/includes/policy-runtime.md && echo OK`
  Expected: `OK`
- [ ] Verify: `find docs/examples/guardrails -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' '`
  Expected: `2`
- [ ] Acceptance: AC1, AC3, AC5
- [ ] Commit: `define canonical policy runtime contract and example guardrails`

### Task 2: Create the `zuvo:guardrails` skill

**Files:** `skills/guardrails/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: Confirm the skill does not exist yet: `test -f skills/guardrails/SKILL.md || echo MISSING`
- [ ] GREEN: Create `skills/guardrails/SKILL.md` using the existing skill template structure. Include mandatory file loading for `policy-runtime.md`, `env-compat.md`, and `codesift-setup.md`; argument parsing for `create`, `list`, `explain`, `simulate`, `disable`, and `enable`; explicit advisory-mode messaging for Codex/Cursor; secret-redaction rules; and artifact-writing instructions for `.zuvo/policies/*.yaml`.
- [ ] Verify: `grep -q "^name: guardrails" skills/guardrails/SKILL.md && grep -q "simulate <policy-id>" skills/guardrails/SKILL.md && grep -q "policy-runtime.md" skills/guardrails/SKILL.md && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC1, AC3
- [ ] Commit: `add guardrails skill for policy authoring and simulation`

### Task 3: Implement the shared Claude hook evaluator and event adapters

**Files:** `hooks/policy-runtime-lib.sh`, `hooks/pre-tool-use`, `hooks/user-prompt-submit`, `hooks/stop`
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: Confirm the runtime files are absent and the event hooks are not yet available: `for f in hooks/policy-runtime-lib.sh hooks/pre-tool-use hooks/user-prompt-submit hooks/stop; do test -f "$f" || echo "MISSING:$f"; done`
- [ ] GREEN: Add a shared shell library that loads canonical policy YAML from `.zuvo/policies/`, normalizes event payloads, evaluates scope and conditions, resolves precedence, downgrades CodeSift-required rules when evidence is unavailable, and emits the normalized decision object. Add three thin event adapters for `PreToolUse`, `UserPromptSubmit`, and `Stop` that parse Claude hook stdin JSON and translate the runtime decision into Claude-compatible JSON output.
- [ ] Verify: `bash -n hooks/policy-runtime-lib.sh hooks/pre-tool-use hooks/user-prompt-submit hooks/stop && echo OK`
  Expected: `OK`
- [ ] Verify: `TMP_DIR=$(mktemp -d) && mkdir -p "$TMP_DIR/.zuvo/policies" && cp docs/examples/guardrails/block-dangerous-bash.yaml "$TMP_DIR/.zuvo/policies/" && printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf ./tmp"}}' "$TMP_DIR" | CLAUDE_PLUGIN_ROOT="$PWD" bash hooks/pre-tool-use | grep -Eq '"decision"[[:space:]]*:[[:space:]]*"block"' && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC1, AC2
- [ ] Commit: `add Claude hook runtime for guardrail evaluation`

### Task 4: Register runtime hooks and make local Claude installs sync them

**Files:** `hooks/hooks.json`, `scripts/install.sh`
**Complexity:** standard
**Dependencies:** Task 3
**Execution routing:** default implementation tier

- [ ] RED: Confirm the repo still exposes only `SessionStart` and that the install script does not sync hook files: `grep -n "SessionStart\\|PreToolUse\\|UserPromptSubmit\\|Stop" hooks/hooks.json` and `grep -n "/hooks" scripts/install.sh || true`
- [ ] GREEN: Extend `hooks/hooks.json` with `PreToolUse`, `UserPromptSubmit`, and `Stop` registrations that call the new event scripts through `run-hook.cmd`. Update `scripts/install.sh` so the Claude install path copies hook files and hook definitions into each cache directory during local development sync. Do not change `run-hook.cmd`; its existing named-hook dispatch is already sufficient.
- [ ] Verify: `grep -q '"PreToolUse"' hooks/hooks.json && grep -q '"UserPromptSubmit"' hooks/hooks.json && grep -q '"Stop"' hooks/hooks.json && echo OK`
  Expected: `OK`
- [ ] Verify: `bash -n scripts/install.sh && grep -q "/hooks/" scripts/install.sh && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC2
- [ ] Commit: `wire guardrail hooks into Claude config and local install flow`

### Task 5: Extend `zuvo:review` with focused review packs

**Files:** `skills/review/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: Confirm the review skill does not yet expose focus packs: `grep -n -- "--focus\\|errors\\|comments\\|simplify" skills/review/SKILL.md || true`
- [ ] GREEN: Update `skills/review/SKILL.md` so `--focus <pack>` is a first-class argument. Define behavior for `errors`, `tests`, `comments`, `types`, and `simplify`; preserve the existing tier system and confidence gate; add pack-specific audit emphasis and report taxonomy; and keep FIX-ALL/FIX-BLOCKING safeguards intact.
- [ ] Verify: `grep -q -- "--focus <pack>" skills/review/SKILL.md && grep -q "errors" skills/review/SKILL.md && grep -q "tests" skills/review/SKILL.md && grep -q "comments" skills/review/SKILL.md && grep -q "types" skills/review/SKILL.md && grep -q "simplify" skills/review/SKILL.md && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC4
- [ ] Commit: `add focused review packs to the review core`

### Task 6: Wire guardrails and focus packs into adjacent skills and routing

**Files:** `skills/ship/SKILL.md`, `skills/code-audit/SKILL.md`, `skills/using-zuvo/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2, Task 5
**Execution routing:** default implementation tier

- [ ] RED: Confirm there is no `guardrails` router entry and no focus-pack references in adjacent skills: `rg -n "guardrails|--focus errors|policy pack" skills/ship/SKILL.md skills/code-audit/SKILL.md skills/using-zuvo/SKILL.md || true`
- [ ] GREEN: Add `zuvo:guardrails` to the router as a utility skill, update routing guidance so policy authoring and runtime-safety requests map correctly, add thin `zuvo:review --focus errors|tests` references inside `skills/ship/SKILL.md`, and add a cross-reference in `skills/code-audit/SKILL.md` where project-specific policy rules overlap with CQ/CAP review.
- [ ] Verify: `grep -q "zuvo:guardrails" skills/using-zuvo/SKILL.md && grep -q -- "--focus errors" skills/ship/SKILL.md && grep -q "policy" skills/code-audit/SKILL.md && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC4, AC5
- [ ] Commit: `wire guardrails and focused review into routing and adjacent skills`

### Task 7: Sync core docs and counts for the new skill surface

**Files:** `README.md`, `docs/skills.md`, `docs/getting-started.md`, `CLAUDE.md`, `package.json`
**Complexity:** standard
**Dependencies:** Task 2, Task 5, Task 6
**Execution routing:** default implementation tier

- [ ] RED: Confirm the repo still describes a 39-skill product surface and has no public `guardrails` references: `rg -n "39 skills|guardrails" README.md docs/skills.md docs/getting-started.md CLAUDE.md package.json`
- [ ] GREEN: Update the public docs and maintainer guide to 40 skills, add `guardrails` to the relevant category tables and descriptions, document focused review packs where review is described, and update `package.json` metadata text so it matches the new capability count.
- [ ] Verify: `rg -q "40 skills|guardrails" README.md docs/skills.md docs/getting-started.md CLAUDE.md package.json && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC4, AC5
- [ ] Commit: `sync core docs and package metadata for guardrails rollout`

### Task 8: Document runtime configuration and advisory CodeSift behavior

**Files:** `docs/configuration.md`, `docs/codesift-integration.md`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`
**Complexity:** standard
**Dependencies:** Task 3, Task 4, Task 7
**Execution routing:** default implementation tier

- [ ] RED: Confirm configuration docs still describe only `SessionStart` and manifests still advertise 39 skills: `rg -n "single \`SessionStart\` hook|39 skills|guardrails|PreToolUse|UserPromptSubmit|Stop" docs/configuration.md docs/codesift-integration.md .claude-plugin/plugin.json .codex-plugin/plugin.json`
- [ ] GREEN: Update configuration docs to describe the new runtime hook layer, policy storage under `.zuvo/policies/`, and platform-specific enforcement vs advisory mode. Update CodeSift docs to explain optional evidence-backed guardrails and downgrade behavior when CodeSift is unavailable. Sync both plugin manifest descriptions to 40 skills.
- [ ] Verify: `rg -q "PreToolUse|UserPromptSubmit|Stop|\\.zuvo/policies|advisory|40 skills|guardrails" docs/configuration.md docs/codesift-integration.md .claude-plugin/plugin.json .codex-plugin/plugin.json && echo OK`
  Expected: `OK`
- [ ] Acceptance: AC2, AC3, AC5
- [ ] Commit: `document runtime hooks and advisory policy behavior`

### Task 9: Sync website skill pages and validation rules

**Files:** `website/skills/guardrails.yaml`, `website/skills/review.yaml`, `website/skills/using-zuvo.yaml`, `website/skills/_schema.yaml`, `scripts/validate-skill-pages.sh`
**Complexity:** standard
**Dependencies:** Task 2, Task 5, Task 6, Task 7
**Execution routing:** default implementation tier

- [ ] RED: Confirm the website layer still expects 39 skill pages and has no guardrails page: `test -f website/skills/guardrails.yaml || echo MISSING && grep -n "EXPECTED_COUNT=39\\|39 skills" scripts/validate-skill-pages.sh website/skills/using-zuvo.yaml website/skills/_schema.yaml`
- [ ] GREEN: Add `website/skills/guardrails.yaml`, update `website/skills/review.yaml` to expose focused review packs, update `website/skills/using-zuvo.yaml` to 40 skills and the new routing role, and update `_schema.yaml` plus `scripts/validate-skill-pages.sh` so the slug allow-list and expected file count include `guardrails`.
- [ ] Verify: `bash scripts/validate-skill-pages.sh`
  Expected: `PASS: All 40 skill YAML files validated successfully`
- [ ] Acceptance: AC4, AC5
- [ ] Commit: `sync website skill metadata and validator for guardrails`
