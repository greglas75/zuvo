#!/usr/bin/env bash
# test-ship-runtime-contracts.sh — the parts of zuvo:ship that are EXECUTABLE must be executable.
#
# ship/SKILL.md is prose an agent runs. Its bash blocks and its cross-file mandates are therefore
# code, and they rotted exactly like code: a 40-agent sweep of 167 ship retros (2026-08-12) found
# gates that could not fire at all, and nothing in the suite noticed because nothing checked the
# instructions against reality.
#
# Each assertion below pins one defect that a real ship run paid for:
#
#   (a) ${PLUGIN_ROOT} — the cross-provider review resolved its script through a variable NO
#       harness sets (they set CLAUDE_PLUGIN_ROOT / CURSOR_PLUGIN_ROOT). The path became
#       "/scripts/adversarial-review.sh", the `[[ -x ]]` guard was false, and the mandatory
#       cross-model gate self-skipped on every platform with a line that reads like a provider
#       fault. Related standing rule: helpers are reached at the version-independent ~/.zuvo/ path.
#   (b) the cross-provider proof — redirecting stdout to /tmp captures the human summary; the
#       canonical `REVIEW BY:` markers the push gate reads exist only in the --artifact file.
#       Ship's most expensive review step produced nothing any gate could verify.
#   (c) tag collision — the bump came from a FILE while the tag namespace is shared with other
#       worktrees and the remote. Nothing checked whether v<candidate> was already published.
#   (d) PR-flow tagging — Phase 3 deliberately does not bump on a feature branch, so an
#       unconditional `git tag v<version>` in Phase 4 re-tags an ALREADY-RELEASED version at
#       unmerged code.
#   (e) test verdict integrity — `runner | tail` makes `$?` tail's status (always 0), and a farm
#       runner evicted before it starts exits 0 with no summary at all. Both read as green.
#   (f) `gh pr create` unconditional — it exits non-zero when the branch already has an open PR,
#       which is the normal shape of a second ship on the same branch.
#   (g) one base — BASE_REF resolved in Phase 0 and reused, so the range Phase 1 baselines against
#       is the range Phase 2 reviews.
#   (h) env-compat vs SAFETY RULE 2 — the include ship MUST load said "never push without explicit
#       user confirmation, regardless of environment" while ship's own rule 2 says push always.
#       The include is what the agent read last, so ship stopped before the push.
#
# STANDALONE (run-all.sh globs tests/skill-suite/test-*.sh and EXECUTES them — no injected
# harness). bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIP="$ROOT/skills/ship/SKILL.md"
ENVC="$ROOT/shared/includes/env-compat.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ ! -f "$SHIP" ]; then
  bad "skills/ship/SKILL.md not found"
  exit 1
fi

# ─── (a) no undefined ${PLUGIN_ROOT} in an executable position ───────────────
# Prose may DISCUSS the old form (the fix comment names it); an assignment may not use it.
if grep -nE '^[[:space:]]*[A-Z_]+=.*\$\{?PLUGIN_ROOT' "$SHIP" >/dev/null 2>&1; then
  bad "(a) ship assigns a path from \${PLUGIN_ROOT} — no harness sets it; the guarded block silently never runs"
else
  pass "(a) no executable use of the undefined \${PLUGIN_ROOT}"
fi

if grep -q 'HOME/.zuvo/adversarial-review\|~/.zuvo/adversarial-review' "$SHIP"; then
  pass "(a2) the cross-provider script is reached at the version-independent ~/.zuvo/ path"
else
  bad "(a2) ship does not resolve adversarial-review at ~/.zuvo/ — a release that prunes the cache dir breaks it mid-session"
fi

# ─── (b) the cross-provider pass must write a gate-readable proof ────────────
if grep -q -- '--artifact "\$ADV_PROOF"' "$SHIP" && grep -q 'zuvo/proofs/' "$SHIP"; then
  pass "(b) cross-provider review writes its proof via --artifact under zuvo/proofs/"
else
  bad "(b) cross-provider review has no --artifact proof path — REVIEW BY: markers exist only in the artifact, so a stdout redirect proves nothing"
fi
if grep -qE '\$AR_RC|AR_RC=' "$SHIP"; then
  pass "(b2) the cross-provider exit code is captured and branched on"
else
  bad "(b2) nothing captures the adversarial exit code — 'no CRITICAL findings' from a pass that never ran reads as clean"
fi

# ─── (c) tag-collision preflight before the bump/tag ─────────────────────────
if grep -q 'ls-remote --tags' "$SHIP" && grep -q 'refs/tags/\$NEXT\|refs/tags/v\$' "$SHIP"; then
  pass "(c) the bump is preflighted against local AND remote release tags"
else
  bad "(c) no tag-collision preflight — a version already published by a concurrent worktree is reused and fails at the final push"
fi
# Naming the forbidden command in order to forbid it is correct and must stay allowed, so scan only
# EXECUTABLE positions: lines inside a fenced code block. Keying off negation words on the same
# line does not work — "Use `git tag -f`, never delete a published tag" carries a negation for a
# different clause and reads as safe.
# Only ```bash / ```sh fences are executable. A plain ``` fence holds the COMPLETION GATE CHECK
# text, where "no `git tag -f`" is the RULE — counting that as a prescription made the guard fail
# on a correct file, which is how a test teaches people to ignore it.
_code_only() {
  awk '
    /^[[:space:]]*```/ {
      if (infence) { infence = 0 } else { infence = 1; isbash = ($0 ~ /```(bash|sh)[[:space:]]*$/) }
      next
    }
    infence && isbash { print }
  ' "$1"
}
if _code_only "$SHIP" | grep -q 'git tag -f'; then
  bad "(c2) a code block in ship runs 'git tag -f' — moving a published tag rewrites what other checkouts already fetched"
else
  pass "(c2) no code block force-tags (prose may still name it to forbid it)"
fi

# ─── (d) PR flow must not tag ────────────────────────────────────────────────
# The tag step has to be flow-conditional; an unconditional `git tag v<version>` on PR flow tags a
# version this run did not produce.
if awk '/^### Step 3: Tag/,/^### Step 4/' "$SHIP" | grep -q 'FLOW.*=.*"pr"\|PR flow → no tag'; then
  pass "(d) the tag step is conditional on flow (PR flow creates no tag)"
else
  bad "(d) Phase 4 Step 3 tags unconditionally — on PR flow that re-tags an already-released version at unmerged code"
fi

# ─── (e) test verdict integrity ──────────────────────────────────────────────
if grep -q 'PIPESTATUS' "$SHIP"; then
  pass "(e) the runner's exit status is read via PIPESTATUS, not a pipe's"
else
  bad "(e) nothing warns that 'runner | tail' makes \$? the pipe's status — every red suite reads green"
fi
# The contract is two-part: parse a summary proving tests EXECUTED, and make its absence a hard
# branch. A printed warning is what the first version did, and a warning nothing enforces is how
# "0 tests" shipped as green.
if grep -q 'TEST_RAN' "$SHIP" && grep -qi 'ENV-RERUN' "$SHIP"; then
  if grep -qi 'TEST_RAN=false is a hard branch\|Do not proceed to' "$SHIP"; then
    pass "(e2) an exit-0 run with no executed-test evidence routes to ENV-RERUN, not to Phase 2"
  else
    bad "(e2) TEST_RAN is computed but nothing forbids proceeding on false — an advisory check is not a gate"
  fi
else
  bad "(e2) nothing requires a parsed runner summary — an evicted farm run exits 0 having tested nothing"
fi

# ─── (f) PR reuse + state-not-exit-code ─────────────────────────────────────
if grep -q 'gh pr view' "$SHIP" && grep -q 'gh pr create' "$SHIP"; then
  pass "(f) the PR path checks for an existing PR before creating one"
else
  bad "(f) 'gh pr create' is unconditional — a second ship on the same branch dies at the last step"
fi
if grep -qi 'MERGED' "$SHIP"; then
  pass "(f2) the merge outcome is verified from PR state, not from an exit code"
else
  bad "(f2) nothing says to verify the merge via 'gh pr view --json state' — gh pr merge can exit non-zero AFTER merging"
fi

# ─── (g) one BASE_REF, resolved once ────────────────────────────────────────
_assigns=$(grep -cE '^[[:space:]]*(BASE_REF)=' "$SHIP" 2>/dev/null || echo 0)
_assigns=$(printf '%s' "$_assigns" | tr -cd '0-9'); [ -n "$_assigns" ] || _assigns=0
# Phase 0 step 3 resolves it in a two-branch if (PR vs release) = 2 assignments + 2 fallbacks.
# Anything beyond that means a later phase re-resolves it and can disagree with Phase 1's baseline.
if [ "$_assigns" -le 4 ]; then
  pass "(g) BASE_REF is resolved in one place ($_assigns assignment lines)"
else
  bad "(g) BASE_REF is assigned $_assigns times — more than one resolution means the baseline and the review can scope to different ranges"
fi

# ─── (h) the include must not forbid the push ship mandates ─────────────────
if [ ! -f "$ENVC" ]; then
  bad "(h) shared/includes/env-compat.md not found (ship loads it as mandatory)"
elif grep -qi 'Never push to a remote repository without explicit user confirmation' "$ENVC"; then
  if grep -qi 'zuvo:ship' "$ENVC" && grep -qi 'exception' "$ENVC"; then
    pass "(h) env-compat's no-push rule names the publishing-skill exception ship depends on"
  else
    bad "(h) env-compat forbids pushing 'regardless of environment' with no exception for zuvo:ship — the include the agent just read contradicts SAFETY RULE 2 at the final step"
  fi
else
  pass "(h) env-compat carries no blanket no-push rule"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
