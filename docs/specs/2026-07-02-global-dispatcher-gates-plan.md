# Implementation Plan: Global git-hook dispatcher gate wiring

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (user-confirmed diagnosis, 2026-07-02)
**plan_revision:** 5
**status:** Approved
**Created:** 2026-07-02
**Tasks:** 5
**Estimated complexity:** 4 standard + 1 complex

## Problem (evidence)

`~/.claude/hooks/pre-push` and `pre-commit` (global `core.hooksPath` dispatchers, populated by
**codesift-mcp setup, NOT tracked in this repo**) are pure pass-throughs: `exec` the repo-local
`.git/hooks/<hook>` if present, else exit 0. The tracked zuvo gates (`hooks/pre-push-gate.sh`
pipeline-entry, `hooks/refactor-safety-gate.sh` work-gate incl. plan→execute bind) sit in the same
installed directory and are NEVER invoked globally. Result: freestyle agents push substantial
unreviewed work in every repo except zuvo-plugin (dogfood `.githooks`). Evidence: QuotasMobi has no
local pre-push (71 commits/3 days ungated); tgm-survey-platform's local pre-push is a type-check
whose `exec` shadows everything global.

## Architecture Summary

- **New tracked sources** `hooks/git-dispatch/pre-push` + `hooks/git-dispatch/pre-commit` (POSIX sh,
  ≤60 lines each): capture stdin ONCE (`feed()` pattern proven in `.githooks/pre-push` — empty input
  emits nothing), run repo-local `.git/hooks/<hook>` first WITHOUT `exec` (propagate failure), then
  ALWAYS chain the zuvo gates from the dispatcher's own directory (`$(dirname "$0")`), fail-open when
  a gate script is missing.
- **Chain map:** pre-push → `pre-push-gate.sh` (git-native stdin mode) + `refactor-safety-gate.sh pre-push`;
  pre-commit → `refactor-safety-gate.sh pre-commit` ONLY.
- **install.sh** ships `hooks/git-dispatch/*` → `~/.claude/hooks/{pre-push,pre-commit}` and wires
  `core.hooksPath` keyed on OUR dispatchers (codesift `post-commit` self-heal preserved, untouched).
  **DELIBERATE SCOPE EXPANSION (rev 2, Issue 3):** every zuvo install now sets global
  `core.hooksPath=~/.claude/hooks` even on machines that never ran codesift — that IS the feature
  (global enforcement for freestyle agents). Uninstall path documented in Task 5:
  `git config --global --unset core.hooksPath` restores stock git behavior.
- **SYMLINK REALITY (rev 2, Issue 1):** on the live machine `~/.claude/hooks/pre-push`, `commit-msg`
  and `prepare-commit-msg` are SYMLINKS to a shared `hook-chain.sh`. A naive `cp` writes THROUGH the
  pre-push symlink and corrupts `hook-chain.sh` for the other two hooks. Install must `rm -f` the
  dispatcher targets first (break the link), then copy — leaving `hook-chain.sh`, `commit-msg`,
  `prepare-commit-msg`, `post-commit` byte-identical.
- Dependency direction: dispatchers → gates → `hooks/lib/*.sh` (existing; no lib changes).

## Technical Decisions

- **TD1 — do NOT chain `pre-commit-adversarial-gate.sh` in the git dispatcher.** Verified: it is a
  PreToolUse-Bash hook — reads tool-input JSON from stdin and `case "$INPUT" in *"git commit"*)` exits 0
  otherwise. In a git-native pre-commit (empty stdin) it is a guaranteed no-op. It stays wired via
  hooks.json (PreToolUse), where it already runs. (Corrects the initial brief, with evidence.)
- **TD2 — run local hook WITHOUT `exec`, propagate rc.** `exec` replaces the process and shadows the
  gates (the tgm-survey-platform failure mode). Local-hook failure still blocks (rc propagated); gates
  run regardless of local hook presence/result.
- **TD3 — stdin captured once, replayed via `feed()`** to local hook AND both gates (a consumed stdin
  is unreplayable; empty input must emit NOTHING — the `.githooks/pre-push` empty-stdin CRITICAL).
- **TD4 — no new env/exempt logic in dispatchers.** Human-exempt lives in the gates
  (`pg_is_agent_env` G8; refactor-gate AI-marker bypass) — dispatchers stay dumb pipes. `ZUVO_ALLOW_ADHOC`
  semantics untouched.
- **TD5 (rev 2) — REPLACE the dispatcher symlink with a regular file, never write through it.**
  `~/.claude/hooks/pre-push` is a symlink to the shared `hook-chain.sh` (also the target of
  `commit-msg` + `prepare-commit-msg`); `install_git_dispatchers()` MUST `rm -f "$hooks_dir/pre-push"
  "$hooks_dir/pre-commit"` BEFORE `cp` so the copy lands as a regular file and `hook-chain.sh`,
  `commit-msg`, `prepare-commit-msg`, `post-commit` remain byte-identical. Our dispatcher is a
  superset (keeps local-hook delegation, adds gates). Never write into any repo's `.git/hooks/` (C2).
- **TD6 — double-run tolerance.** A repo whose local hook already calls `refactor-safety-gate.sh`
  (install-refactor-gate opt-in) will run it twice; the gate is read-only + idempotent — accepted.
- **TD7 — zuvo-plugin itself is unaffected** (local `core.hooksPath=.githooks` overrides global), so the
  dogfood path stays canonical.

## Quality Strategy

Shell TDD via `tests/hooks/test-global-dispatch.sh` (bash, temp repos, `GIT_CONFIG_GLOBAL=/dev/null`,
stub gates + stub local hooks; exact exit codes + stderr tokens, no tautologies). Risk areas: stdin
replay (empty vs multi-ref), rc aggregation (local-fail + gate-pass and vice versa), fail-open when
gates missing, recursion guard (dispatcher must not re-enter itself when a repo's local hook is a
symlink to the dispatcher). Per-task adversarial (Step 7b) + acceptance proofs; live clone-sim smoke.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | stdin captured once, feed() replay, empty→nothing | requirement | Task 1 | TD3 |
| G2 | local hook runs first, no exec, failure propagates | requirement | Task 1, Task 2 | TD2 |
| G3 | gates ALWAYS chained (pre-push: pipeline+work; pre-commit: work) | requirement | Task 1, Task 2 | TD1 map |
| G4 | human-exempt + ZUVO_ALLOW_ADHOC untouched | constraint | Task 1, Task 2, Task 4 | TD4 |
| G5 | tests: 6 mandated cases | deliverable | Task 1, Task 2 | RED suites |
| G6 | install.sh ships dispatchers + live clone-sim verify | requirement | Task 3, Task 4 | TD5 |
| C1 | dispatcher sources tracked in THIS repo | constraint | Task 1, Task 2 | hooks/git-dispatch/ |
| C2 | never clobber a repo's local .git/hooks | constraint | Task 3 | install target is ~/.claude/hooks only |
| D1 | docs + version decision | deliverable | Task 5 | always-run gate |

## Review Trail
- Phase 1: direct (small/light scope)
- Plan-DAG lint: rev 1 → PASS (5 tasks, 0 violations)
- Plan reviewer: revision 1 → ISSUES FOUND (7: HIGH symlink-corruption of shared hook-chain.sh via cp-through-symlink; false-green cmp; unflagged hooksPath scope expansion; resolver portability; Windows; G4/C2 assertion-only; verify one-file). ALL incorporated in rev 2 (TD5 rm-first, symlink-layout RED, deliberate-expansion + uninstall, portable pp() + ZUVO_DISPATCH_ACTIVE latch, shebang + Windows honest-limit, ADHOC + .git/hooks-unchanged cases, verify-both).
- Plan reviewer: revision 2 → all 7 issues verified RESOLVED; 3 minor count/tautology defects flagged with exact fixes + "once the case counts are reconciled (items 1-2), this is ready to execute" → rev 3 applies the reviewer's own fixes verbatim (case (8) ADHOC in RED, 8/14 counts, self-cmp tautology removed, ZUVO_DISPATCH_ACTIVE export spelled out) → APPROVED (conditional fixes applied)
- Cross-model validation: executed (gemini, --rotate --mode plan) → 2 CRITICAL + 3 WARNING. Dispositions: CRIT-1 pre-commit stdin-hang = REAL → rev 4 forbids `input=$(cat)` in pre-commit + hang-guard RED case; CRIT-2 "$ZUVO_DIR is the output dir" = FP ($ZUVO_DIR is the repo root — install.sh:19 `cd "$(dirname ...)/.."`); WARN latch-breaks-nested-git = REAL → rev 4 scopes the latch to `"$HOOK_NAME:$R"`; WARN local-before-gates = design (rc aggregation makes order block-equivalent; local-first preserves existing UX) — no change; WARN feed-SIGPIPE = harmless (pipeline rc = gate's rc, no set -e) — no change.
- Plan reviewer: revision 4 → both cross-model fixes CONFIRMED correct (stdin-hang forbid + hang-guard sound; scoped latch closes nesting, no residual recursion), both dispositions CONFIRMED (CRIT-2 FP: gemini conflated install.sh's repo-root $ZUVO_DIR with the gate's unrelated output-dir local; SIGPIPE harmless). 1 count regression + 2 nits, "once … 15 cases and the hang-guard is enumerated as Task 2 case (7), this is ready to execute" → rev 5 applies verbatim (case (7), 15 total, HOOK_NAME=$(basename "$0") defined) → APPROVED (conditional fixes applied)
- Status gate: Approved (user, 2026-07-02)


## Task Breakdown

### Task 1: Tracked pre-push dispatcher (stdin-once + local-no-exec + gate chain)
**Files:** `hooks/git-dispatch/pre-push`, `tests/hooks/test-global-dispatch.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none

- [ ] RED: `tests/hooks/test-global-dispatch.sh` (pre-push section) asserts, each with exact exit code + a specific stderr/stdout token: (1) no local hook + agent env + blocking stub gate → exit≠0, token from gate; (2) local hook exits 7 + passing gates → exit≠0 (local failure propagates); (3) local hook passes + blocking stub gate → exit≠0 (gates run AFTER local, `exec`-shadowing is dead); (4) human env (`env -u CLAUDECODE -u ZUVO_AI_RUN…`) + real `pre-push-gate.sh` stub honoring G8 → exit 0; (5) empty stdin → exit 0 and stub gate records NO ref line (no synthetic blank ref); (6) gates absent from dispatcher dir → exit 0 (fail-open); (7) recursion guard: local `.git/hooks/pre-push` symlinked to the dispatcher itself → terminates, no fork bomb; (8) `ZUVO_ALLOW_ADHOC=1` + agent env + blocking range → exit 0 (escape passes through untouched — G4).
- [ ] GREEN: `hooks/git-dispatch/pre-push` (`#!/bin/sh`, ≤60 lines): `D=$(cd "$(dirname "$0")" && pwd)`; `HOOK_NAME=$(basename "$0")` (rev 5 — defines the latch key); `input=$(cat)`; `feed(){ [ -n "$input" ] && printf '%s\n' "$input"; }`; resolve repo root; run `"$R/.git/hooks/pre-push"` via feed WITHOUT exec when executable AND not the dispatcher itself — recursion guard via PORTABLE resolver (rev 2, Issue 4): `pp(){ CDPATH= cd -- "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"; }`, compare `pp local` vs `pp $0`, fail-open; re-entry latch as the HARD stop, SCOPED per hook+repo (rev 4, cross-model WARNING: a bare `=1` flag would also skip local hooks of NESTED git operations in a DIFFERENT repo): latch value `"$HOOK_NAME:$R"` — skip the local-hook branch only when `"$ZUVO_DISPATCH_ACTIVE"` equals the CURRENT hook:repo pair; `ZUVO_DISPATCH_ACTIVE="$HOOK_NAME:$R"; export ZUVO_DISPATCH_ACTIVE` BEFORE invoking the local hook; `rc` aggregation; then `feed | "$D/pre-push-gate.sh"` and `feed | "$D/refactor-safety-gate.sh" pre-push` each `|| rc=1`, each guarded `[ -x … ] &&` (fail-open); `exit $rc`.
- [ ] Verify: `bash tests/hooks/test-global-dispatch.sh`
  Expected: `ALL PASS` (pre-push section, 8 cases), exit 0
- [ ] Acceptance Proof:
  - AC-G1G2G3 (pre-push):
    - Surface: backend-logic
    - Proof: run the test suite; additionally `printf '' | hooks/git-dispatch/pre-push` in a temp repo with a ref-recording stub gate
    - Expected: exit 0; stub's recorded input is EMPTY (no synthetic ref); blocking cases exit 1 with gate token
    - Artifact: `zuvo/proofs/task-1-dispatch-prepush.txt`
- [ ] Commit: `feat(hooks): tracked global pre-push dispatcher — local hook (no exec) + always-chain pipeline/work gates`

### Task 2: Tracked pre-commit dispatcher
**Files:** `hooks/git-dispatch/pre-commit`, `tests/hooks/test-global-dispatch.sh`
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 1 (same test file — serialized per rule 13; reuses harness helpers)

- [ ] RED: pre-commit section in the SAME test file: (1) no local hook + agent env + refactor CONTRACT prove-skipped fixture → blocked with `BLOCK:` token (work-gate fires); (2) local pre-commit exits 7 → propagates; (3) local passes + pending-plan fixture (plan→execute bind) → blocked; (4) human env → exit 0; (5) gate absent → exit 0; (6) recursion guard (symlink-to-self) → terminates; (7) hang-guard (rev 5): dispatcher completes under `timeout 5` with stdin attached to an open-but-silent pipe (a re-introduced `input=$(cat)` would exit 124 and fail RED).
- [ ] GREEN: `hooks/git-dispatch/pre-commit` (`#!/bin/sh`, ≤40 lines): **NO `input=$(cat)` — FORBIDDEN here** (rev 4, cross-model CRITICAL: git-native pre-commit inherits the terminal's stdin with no EOF contract — a `cat` capture HANGS interactive commits). Do not touch stdin at all: invoke the local hook directly (it inherits stdin naturally) and `"$D/refactor-safety-gate.sh" pre-commit </dev/null` (the gate reads `git diff --cached`, not stdin). Chain ONLY the work-gate (TD1: pre-commit-adversarial-gate.sh is PreToolUse-only — documented no-op in git context). Hang-guard lives in RED case (7) above (rev 5).
- [ ] Verify: `bash tests/hooks/test-global-dispatch.sh`
  Expected: `ALL PASS` (both sections, 15 cases: 8 pre-push + 7 pre-commit), exit 0
- [ ] Acceptance Proof:
  - AC-G2G3 (pre-commit):
    - Surface: backend-logic
    - Proof: temp repo, prove-skipped refactor CONTRACT fixture, `ZUVO_AI_RUN=1 git commit` through the dispatcher
    - Expected: exit≠0 + `BLOCK:` on stderr; same commit with prove-complete fixture → exit 0
    - Artifact: `zuvo/proofs/task-2-dispatch-precommit.txt`
- [ ] Commit: `feat(hooks): tracked global pre-commit dispatcher — local hook (no exec) + work-gate chain`

### Task 3: install.sh ships the dispatchers
**Files:** `scripts/install.sh`, `tests/hooks/test-global-dispatch.sh`
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 1, Task 2 (ships their artifacts)

- [ ] RED: test case (install section) against a temp `$HOME` (`HOME=$TMP` fake) that SEEDS THE REAL SYMLINK LAYOUT (rev 2, Issue 2): `hook-chain.sh` (known content) + `pre-push -> hook-chain.sh` + `commit-msg -> hook-chain.sh` symlinks + a `post-commit` regular file. After the install step assert: (a) `hook-chain.sh`, `commit-msg` (via its link target), `post-commit` are BYTE-IDENTICAL to before; (b) `~/.claude/hooks/pre-push` and `pre-commit` are now REGULAR files (`[ ! -L ]`) equal (`cmp`) to `hooks/git-dispatch/*`; (c) C2 (rev 2, Issue 6): a temp repo's `.git/hooks/` content is unchanged after install (no file added/modified).
- [ ] GREEN: new `install_git_dispatchers()` in install.sh: `rm -f "$hooks_dir/pre-push" "$hooks_dir/pre-commit"` (break the hook-chain.sh symlink — TD5) then `cp "$ZUVO_DIR"/hooks/git-dispatch/{pre-push,pre-commit} "$hooks_dir/"` + `chmod +x`, called from the global-wiring section BEFORE the hooksPath block; hooksPath wiring condition extended: wire when OUR dispatchers are installed (keep the codesift `post-commit` self-heal + stale-path repair logic untouched). NEVER write into any repo's `.git/hooks/` (C2).
- [ ] Verify: `bash tests/hooks/test-global-dispatch.sh && bash -n scripts/install.sh`
  Expected: `ALL PASS`, both exit 0
- [ ] Acceptance Proof:
  - AC-G6a:
    - Surface: config
    - Proof: `./scripts/install.sh > /tmp/inst.log 2>&1; [ ! -L ~/.claude/hooks/pre-push ] && cmp ~/.claude/hooks/pre-push hooks/git-dispatch/pre-push && cmp ~/.claude/hooks/pre-commit hooks/git-dispatch/pre-commit && grep -q 'HOOK_NAME=$(basename' ~/.claude/hooks/hook-chain.sh && ! grep -q 'pre-push-gate' ~/.claude/hooks/hook-chain.sh` (rev 3: self-cmp tautology removed — the grep pair is the uncorrupted-hook-chain check; byte-identity gate lives in Task 3 RED)
    - Expected: install exit 0; pre-push is a REGULAR file matching the tracked source (`! -L` — the symlink-follow trap from Issue 2 cannot false-pass); hook-chain.sh uncorrupted
    - Artifact: `zuvo/proofs/task-3-install-dispatch.txt`
- [ ] Commit: `build(install): ship tracked git dispatchers to ~/.claude/hooks (gates now global)`

### Task 4: Live clone-sim smoke (QuotasMobi-like) + smoke runner
**Files:** `tests/hooks/smoke-global-dispatch.sh`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 3 (installed dispatchers are the object under test)

- [ ] RED: this task AUTHORS the smoke runner (rule 8a) `tests/hooks/smoke-global-dispatch.sh`: temp bare remote + clone with NO local hooks, global-style dispatcher invoked as git would (via the INSTALLED `~/.claude/hooks/pre-push`); seed a substantial (≥3 prod files / ≥150 lines) unreviewed commit range.
- [ ] GREEN: (script only — no production code) three scenarios: (S1) agent env (`ZUVO_AI_RUN=1`) push → BLOCKED, stderr contains `unreviewed`; (S2) human env (all AI markers unset) push → exit 0; (S3) repo WITH a failing local type-check-style hook → exit≠0 AND (with passing local hook + agent env + unreviewed range) still BLOCKED — the shadowing bug is dead.
- [ ] Verify: `bash tests/hooks/smoke-global-dispatch.sh`
  Expected: `ALL SMOKE PASS`, exit 0
- [ ] Acceptance Proof:
  - AC-G6b:
    - Surface: integration
    - Proof: run the smoke runner against the INSTALLED `~/.claude/hooks` dispatchers
    - Expected: S1 blocked / S2 passes / S3 both assertions — `ALL SMOKE PASS`
    - Artifact: `zuvo/proofs/smoke-global-dispatch.txt`
- [ ] Commit: `test(hooks): global-dispatcher smoke — freestyle agent push blocked, human exempt, local hook honored`

### Task 5: Docs + version decision (always-run gate)
**Files:** `docs/pipeline.md`, `CLAUDE.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 4

- [ ] RED: docs-only — no test file (explicit per rule 12). Grep-verifiable claims only.
- [ ] GREEN: docs/pipeline.md "Pipeline-entry enforcement" gains the global-dispatcher layer row (scope: every repo under global hooksPath; honest limits (rev 2, Issues 3+5): repo-local core.hooksPath overrides — e.g. Husky repos — bypass the global layer; Windows relies on Git-for-Windows bash executing the extensionless `#!/bin/sh` hooks; **uninstall:** `git config --global --unset core.hooksPath` restores stock git; local `.git/hooks` opt-ins double-run harmlessly); CLAUDE.md enforcement table updated. Print `[DECISION: version bump = minor|patch] → COMPLETE` marker (rule 15).
- [ ] Verify: `test "$(grep -l git-dispatch docs/pipeline.md CLAUDE.md | wc -l | tr -d ' ')" = "2"`
  Expected: exit 0 (BOTH files document the layer — rev 2, Issue 7)
- [ ] Acceptance Proof:
  - AC-D1:
    - Surface: docs
    - Proof: `grep -n 'git-dispatch' docs/pipeline.md CLAUDE.md`
    - Expected: layer documented in both, incl. the Husky/hooksPath-override honest limit
    - Artifact: `zuvo/proofs/task-5-docs.txt`
- [ ] Commit: `docs: global git-dispatch gate layer — every repo gated, freestyle included`

## Whole-feature Smoke Proofs

- **SMOKE1 — freestyle-agent push is gated globally**
  - Preconditions: v-current install (`./scripts/install.sh` done, Task 3), temp bare remote + clone with NO local hooks, substantial unreviewed range
  - Proof: `bash tests/hooks/smoke-global-dispatch.sh` (Task 4 runner; S1 agent-blocked, S2 human-pass, S3 local-hook honored + gates-still-run)
  - Expected: `ALL SMOKE PASS`
  - Artifact: `zuvo/proofs/smoke-global-dispatch.txt`
