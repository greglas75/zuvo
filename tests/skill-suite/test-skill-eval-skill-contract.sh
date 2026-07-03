#!/usr/bin/env bash
# test-skill-eval-skill-contract.sh — structure/content contract for the
# zuvo:skill-eval skill (Task 8).
#
# RED-first: authored BEFORE skills/skill-eval/ exists. Fails first on the
# missing skill dir (assert_file_exists aborts), which is the intended RED
# evidence; once SKILL.md + agents/executor.md + agents/grader.md are authored,
# every assertion must pass.
#
# Verifies:
#   (1) SKILL.md + agents/{executor,grader}.md exist;
#   (2) SKILL.md frontmatter name == skill-eval, H1 == '# zuvo:skill-eval';
#   (3) Argument Parsing declares [skill-name], --compare, --all-evals;
#   (4) Mandatory File Loading references eval-schema.md + report-output-location.md
#       + run-logger.md;
#   (5) phases reference agents/executor.md + agents/grader.md;
#   (6) reports are written under zuvo/reports/;
#   (7) comparison mode materializes the OLD version under zuvo/context/ via git show;
#   (8) the two --compare failure guards (not-a-git-repo vs ref/path-not-found) are
#       present AND are DISTINCT strings (extract both, assert inequality);
#   (9) grader.md carries the spike-proven per-assertion scoring contract
#       (text/passed/evidence fields + judge-ONLY-the-transcript discipline +
#       'absent: ' evidence format for false verdicts);
#  (10) executor.md frontmatter name == executor;
#  (11) STRUCTURAL LINT — validate-skills.sh --root on a skill-eval-ONLY fixture
#       (shared/ copied so includes resolve) exits 0 with ERRORS: 0. A skill-eval-only
#       fixture is used deliberately: repo-wide count-consistency is legitimately RED
#       between Task 8 (dir added) and Task 9 (counts bumped 54->55), so the full-repo
#       count check is NOT exercised here — only skill-eval's own structural conformance.
#
# Idioms adapted from tests/skill-suite/test-validate-skills-contract.sh (assert.sh,
# mktemp+trap, validate-skills.sh --root fixture). bash 3.2-compatible (macOS default).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/seo-suite/assert.sh
source "$ROOT_DIR/tests/seo-suite/assert.sh"

SKILL="$ROOT_DIR/skills/skill-eval/SKILL.md"
EXECUTOR="$ROOT_DIR/skills/skill-eval/agents/executor.md"
GRADER="$ROOT_DIR/skills/skill-eval/agents/grader.md"

# ── (1) files exist (fails first at RED — skill dir missing) ──────────────────
assert_file_exists "$SKILL"
assert_file_exists "$EXECUTOR"
assert_file_exists "$GRADER"
pass "skill-eval SKILL.md + agents/executor.md + agents/grader.md exist"

# ── (2) SKILL.md frontmatter name + H1 ───────────────────────────────────────
require_grep '^name: skill-eval[[:space:]]*$' "$SKILL"
require_grep '^# zuvo:skill-eval' "$SKILL"
pass "frontmatter name: skill-eval + H1 '# zuvo:skill-eval'"

# ── (3) Argument Parsing tokens ──────────────────────────────────────────────
require_grep '^#+[[:space:]]+Argument Parsing' "$SKILL"
assert_contains "$SKILL" '[skill-name]'
assert_contains "$SKILL" '--compare'
assert_contains "$SKILL" '--all-evals'
pass "Argument Parsing declares [skill-name], --compare, --all-evals"

# ── (4) Mandatory File Loading references ─────────────────────────────────────
require_text 'Mandatory File Loading' "$SKILL"
assert_contains "$SKILL" 'eval-schema.md'
assert_contains "$SKILL" 'report-output-location.md'
assert_contains "$SKILL" 'run-logger.md'
pass "MFL references eval-schema.md + report-output-location.md + run-logger.md"

# ── (5) phases reference the agent files ─────────────────────────────────────
assert_contains "$SKILL" 'agents/executor.md'
assert_contains "$SKILL" 'agents/grader.md'
pass "phases reference agents/executor.md + agents/grader.md"

# ── (6) reports under zuvo/reports/ ──────────────────────────────────────────
assert_contains "$SKILL" 'zuvo/reports/'
pass "reports written under zuvo/reports/"

# ── (7) comparison mode materializes OLD version under zuvo/context/ ─────────
assert_contains "$SKILL" 'git show'
assert_contains "$SKILL" 'zuvo/context/skill-eval-baseline-'
pass "comparison mode: git show <ref> -> zuvo/context/skill-eval-baseline-<skill>"

# ── (8) the two --compare guards are present AND distinct strings ────────────
# extract the message text after each GUARD_ token, up to the closing backtick.
MA="$(grep -F 'GUARD_NO_GIT:' "$SKILL" | head -1 | sed 's/.*GUARD_NO_GIT: //; s/`.*//')"
MB="$(grep -F 'GUARD_BAD_REF:' "$SKILL" | head -1 | sed 's/.*GUARD_BAD_REF: //; s/`.*//')"
[ -n "$MA" ] || fail "not-a-git-repo guard (GUARD_NO_GIT) missing from SKILL.md"
[ -n "$MB" ] || fail "ref/path-not-found guard (GUARD_BAD_REF) missing from SKILL.md"
[ "$MA" != "$MB" ] || fail "the two --compare guard messages must be DISTINCT strings (got identical: '$MA')"
pass "distinct --compare guards: not-a-git-repo != ref-not-found"

# ── (9) grader.md spike-proven per-assertion scoring contract ────────────────
require_grep '^name: grader[[:space:]]*$' "$GRADER"
assert_contains "$GRADER" '"text"'
assert_contains "$GRADER" '"passed"'
assert_contains "$GRADER" '"evidence"'
assert_contains "$GRADER" 'Judge ONLY the transcript'
assert_contains "$GRADER" 'absent: '
pass "grader.md carries spike scoring contract (text/passed/evidence + judge-only-transcript + absent:)"

# ── (10) executor.md frontmatter ─────────────────────────────────────────────
require_grep '^name: executor[[:space:]]*$' "$EXECUTOR"
pass "executor.md frontmatter name: executor"

# ── (10b) regression locks for the round-1 adversarial fixes ─────────────────
# grader must be transcript-only: no tools (contradiction fix — grader had
# ToolSearch which could load repo-access tools and invalidate the eval).
require_grep '^tools: \[\][[:space:]]*$' "$GRADER"
# isolation must fail closed rather than run in the live tree.
assert_contains "$SKILL" 'BLOCKED_NO_ISOLATION'
# transcript sanitization must be a concrete code step (os.urandom nonce), not a
# regex the orchestrator is told to "apply mentally".
assert_contains "$SKILL" 'os.urandom'
# eval-schema.md is the trust anchor — its absence must hard-stop, not degrade.
assert_contains "$SKILL" 'BLOCKED_NO_SCHEMA'
pass "adversarial-fix regression locks (r1): grader tools:[], fail-closed isolation, coded sanitization, schema hard-stop"

# ── (10c) regression locks for the round-2 adversarial fixes ─────────────────
# per-case isolation must be reclaimed on interrupt (EXIT trap), not orphaned.
assert_contains "$SKILL" 'trap '
# sanitizer emits nonce+transcript as JSON (grader.md owns the fence) — no double-fence.
assert_contains "$SKILL" 'json.dumps'
# non-UTF-8 transcript bytes must degrade, not crash the grader pipeline.
assert_contains "$SKILL" 'errors="replace"'
# --compare must skip cleanly on a guard hit (no fall-through zero-byte baseline).
assert_contains "$SKILL" 'SKIP_COMPARE'
pass "adversarial-fix regression locks (r2): EXIT-trap cleanup, JSON nonce (no double-fence), UTF-8-safe, clean SKIP_COMPARE guard"

# ── (10d) regression locks for the round-3 adversarial fixes ─────────────────
# --compare must materialize the OLD bundle by re-running with the ref (TARGET_REF),
# NOT revert to a single git-show SKILL.md (which drops agents + breaks paths). This
# Phase-4-specific token is the real guard (the generic 'git worktree add' appears in
# Phase 2 regardless, so it can't prove the compare path — claude INFO).
assert_contains "$SKILL" 'TARGET_REF'
# hard tool deps must preflight (fail loud), never crash mid-pipeline as a fake regression.
assert_contains "$SKILL" 'BLOCKED_NO_PYTHON'
assert_contains "$SKILL" 'BLOCKED_NO_TRANSCRIPT_CAPTURE'
# infra failures (executor/grader) must be a recorded status + excluded from the
# behavioral pass rate (reported separately), never a false regression.
assert_contains "$SKILL" 'executor-failed'
assert_contains "$SKILL" 'INCONCLUSIVE'
pass "adversarial-fix regression locks (r3): TARGET_REF bundle, python/capture preflight, infra-failure accounting"

# push-prevention must NOT mutate a SHARED worktree config. The dangerous
# 'git remote set-url --push' must be ABSENT; push is neutralized by removing origin
# from the workspace's OWN (copied/cloned) config.
if grep -Fq -- 'remote set-url --push' "$SKILL"; then
  fail "SKILL.md still contains the config-corrupting 'remote set-url --push'"
fi
assert_contains "$SKILL" 'remote remove'
# current-version isolation must carry UNCOMMITTED changes (cp -R the working tree).
assert_contains "$SKILL" 'cp -R'
# transcript-capture feasibility must be a concrete canary probe, not phantom prose.
assert_contains "$SKILL" 'canary'
# grader reordering (same length, wrong order) must be caught via a positional text
# cross-check, not silently accepted.
assert_contains "$SKILL" 'reorder'
pass "adversarial-fix regression locks (r4): safe push-neutralize (remote remove origin), uncommitted-safe cp -R, concrete capture canary, reorder cross-check"

# ── (10f) regression locks for the round-5 adversarial fixes ─────────────────
# isolation must use an INDEPENDENT clone (own branch namespace), never a git worktree
# (which shares refs — an executor could 'git branch -D' the dev's real branches).
assert_contains "$SKILL" 'git clone --local'
if grep -Fq -- 'git worktree add' "$SKILL"; then
  fail "SKILL.md still USES 'git worktree add' (shares branch namespace; use an independent clone/copy)"
fi
# the sandbox must STRIP evals/ so the executor cannot read its own grading assertions.
assert_contains "$SKILL" 'cannot read the assertions'
# a non-auto-capture runtime must DEGRADE to ACTION_LOG mode, not be unusable.
assert_contains "$SKILL" 'ACTION_LOG mode'
# 120k JSON must be written to a FILE (Bash-tool stdout would truncate it).
assert_contains "$SKILL" 'SAN_FILE'
# --all-evals re-run dedup must be a deterministic per-corpus blob hash.
assert_contains "$SKILL" 'git hash-object'
pass "adversarial-fix regression locks (r5): independent clone (no worktree), evals-strip anti-cheat, reachable ACTION_LOG fallback, file-output (no stdout truncation), deterministic dedup"

# ── (11) structural lint on a skill-eval-only fixture ────────────────────────
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/skills"
cp -R "$ROOT_DIR/skills/skill-eval" "$FIX/skills/skill-eval"
cp -R "$ROOT_DIR/shared" "$FIX/shared"      # so ../../shared/includes/*.md tokens resolve
set +e
LINT_OUT="$(bash "$ROOT_DIR/scripts/validate-skills.sh" --root "$FIX" 2>&1)"
LINT_RC=$?
set -e
[ "$LINT_RC" -eq 0 ] || fail "skill-eval fixture lint should exit 0, got $LINT_RC (output: $LINT_OUT)"
printf '%s\n' "$LINT_OUT" | grep -Fq -- "ERRORS: 0" \
  || fail "skill-eval fixture lint should report 'ERRORS: 0' (output: $LINT_OUT)"
printf '%s\n' "$LINT_OUT" | grep -Fq -- "include-integrity: OK" \
  || fail "skill-eval fixture should pass include-integrity (output: $LINT_OUT)"
pass "skill-eval passes validate-skills.sh --root structural lint (ERRORS: 0, include-integrity OK)"

pass "skill-eval-skill-contract"
