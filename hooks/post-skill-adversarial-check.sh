#!/usr/bin/env bash
# PostToolUse hook for Skill calls.
# After skills that REQUIRE adversarial review, injects a mandatory
# reminder if adversarial-review was not run during the skill.
#
# This catches the "rush to finish" pattern where the agent skips
# Phase 4.5 (adversarial) and jumps straight to completion report.

set -euo pipefail

INPUT=$(cat 2>/dev/null || true)

# Extract skill name — only trigger on skills that require adversarial
SKILL_NAME=""
REVIEW_MODE="code"
for s in write-tests fix-tests write-e2e; do
  if echo "$INPUT" | grep -qi "zuvo:${s}"; then
    SKILL_NAME="$s"
    REVIEW_MODE="test"
    break
  fi
done
if [ -z "$SKILL_NAME" ]; then
  for s in build execute refactor debug receive-review seo-fix; do
    if echo "$INPUT" | grep -qi "zuvo:${s}"; then
      SKILL_NAME="$s"
      REVIEW_MODE="code"
      break
    fi
  done
fi

# Not a relevant skill — exit silently
[ -z "$SKILL_NAME" ] && exit 0

# Did this skill actually run its adversarial pass?
#
# THE LEDGER, NOT THE PROSE. Until 2026-09-22 this read runs.log and passed when the word
# "adversarial" appeared anywhere in the skill's free-text note column. Measured over 1,115
# qualifying skill runs since 2026-08-01: that note carries the word in **6%** of them, while
# ~/.zuvo/adversarial.log — the driver's own per-invocation ledger — holds a real call for
# **94%**. So the hook was telling ~19 runs out of 20 to re-run a review they had already run,
# and the cost of obeying is a second full multi-provider pass.
#
# THE WINDOW. The old one was 15 minutes. The gap between a skill's adversarial call and the
# end of that skill run, same 1,115 runs: p50 1.0 min, p75 2.8, p90 9.1, p95 15.8, max 662.
# Fifteen minutes cuts at the 95th percentile, so ~6% of runs were late by construction — a
# long write-tests or refactor reviews early and keeps working. 45 minutes covers the tail
# without turning the check into "somebody reviewed something today".
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
WINDOW_MIN="${ZUVO_ADV_CHECK_WINDOW_MIN:-45}"
case "$WINDOW_MIN" in ''|*[!0-9]*) WINDOW_MIN=45 ;; esac
ADV_LOG="$HOME/.zuvo/adversarial.log"
LOG="$HOME/.zuvo/runs.log"
FOUND=false

CUTOFF=$(date -u -v-"${WINDOW_MIN}"M +%Y-%m-%dT%H:%M 2>/dev/null \
  || date -u -d "${WINDOW_MIN} minutes ago" +%Y-%m-%dT%H:%M 2>/dev/null || echo "")

# 1. The driver's ledger. Column 17 (project) was added the same day as this change, so rows
#    without it are matched on time alone rather than discarded — an older row is still
#    evidence that a review ran, and discarding it would recreate the false nag it fixes.
if [ "$FOUND" = "false" ] && [ -f "$ADV_LOG" ] && [ -n "$CUTOFF" ]; then
  if awk -F'\t' -v proj="$PROJECT" -v cutoff="$CUTOFF" '
       $1 == "SUMMARY" || $1 == "date" || $1 ~ /^#/ { next }
       $1 >= cutoff && (NF < 17 || $17 == proj || $17 == "unknown") { found=1 }
       END { exit !found }' "$ADV_LOG" 2>/dev/null; then
    FOUND=true
  fi
fi

# 2. Fallback: the old runs.log prose match, kept for hosts with no adversarial.log yet.
#    Narrowed to say what it means — a note recording that the pass was SKIPPED is not
#    evidence that it ran, and the unanchored /adversarial/ match accepted exactly that.
if [ "$FOUND" = "false" ] && [ -f "$LOG" ] && [ -n "$CUTOFF" ]; then
  if awk -F'\t' -v proj="$PROJECT" -v cutoff="$CUTOFF" '
       $1 >= cutoff && $3 == proj && /adversarial/ &&
       !/adversarial[^\t]{0,40}(skip|not run|none|BLOCKED|degraded)/ { found=1 }
       END { exit !found }' "$LOG" 2>/dev/null; then
    FOUND=true
  fi
fi

[ "$FOUND" = "true" ] && exit 0

# Inject mandatory reminder
cat <<HOOKEOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "MANDATORY: zuvo:${SKILL_NAME} requires adversarial review but none was detected. Run NOW — build the review patch with the scoped helper (it NEVER stages and never touches the git index), capture its exit code, then pipe the patch in: if [ -x \"\$HOME/.zuvo/build-review-patch\" ]; then _prc=0; _patch=\$(\"\$HOME/.zuvo/build-review-patch\") || _prc=\$?; if [ \"\$_prc\" -eq 3 ]; then echo \"adversarial review: skipped (no changes)\"; elif [ \"\$_prc\" -ne 0 ]; then echo \"BLOCKED: build-review-patch failed (rc=\$_prc). Adversarial review did NOT run; do NOT proceed to commit and do NOT report this skill complete\" >&2; exit 1; else printf '%s\\\\n' \"\$_patch\" | adversarial-review --json --mode ${REVIEW_MODE}; fi; else adversarial-review --json --mode ${REVIEW_MODE} --files \"<changed files>\"; fi — exit 3 (no changes in scope) is the ONLY non-zero code that may proceed. Never build the review input by staging. This is Phase 4.5 — it is NOT optional. Do NOT deliver results to the user without running adversarial review first."
  }
}
HOOKEOF

exit 0
