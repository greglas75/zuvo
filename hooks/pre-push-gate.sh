#!/usr/bin/env bash
# Pre-push gate — PRIMARY local enforcement of pipeline entry.
#
# Two invocation modes (auto-detected from stdin):
#
#   1. GIT-NATIVE pre-push hook (the canonical path). git feeds one line per
#      pushed ref on stdin: "<local_ref> <local_sha> <remote_ref> <remote_sha>".
#      This range is EXACT and immune to pull/checkout/worktree/compaction.
#      For each pushed range: if the invocation is an AGENT and the range is
#      substantial AND definitively NOT review-covered AND no adhoc escape →
#      BLOCK the push (exit 1). Human pushes are exempt.
#
#   2. LEGACY PreToolUse-Bash hook (Claude/Codex/Antigravity). stdin = tool-input
#      JSON containing the command. Preserves the original runs.log review check
#      for "git push" / "gh pr create" so existing wiring keeps working.
#
# FAIL-OPEN: missing lib / no repo / malformed input / git failure → exit 0.
# The CI gate (server-side, unbypassable) is the backstop if a local fail-open
# lets something slip.

set -uo pipefail   # deliberately NOT -e: a benign error must never opaque-block

INPUT=$(cat 2>/dev/null || true)

# Locate + source the shared lib (fail-open if absent).
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -r "$_self_dir/lib/pipeline-gate-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_dir/lib/pipeline-gate-lib.sh"
fi

# ---- mode detection --------------------------------------------------------
looks_native() {
  # A git pre-push stdin line: 4 fields, fields 2 & 4 are hex SHAs (or zeros).
  printf '%s\n' "$INPUT" \
    | grep -qE '^[^[:space:]]+ [0-9a-f]{7,64} [^[:space:]]+ [0-9a-f]{7,64}([[:space:]]*)$'
}

# ---- mode 1: git-native canonical-range gate -------------------------------
gate_native() {
  [ "${PG_LIB_LOADED:-}" = "1" ] || return 0          # no lib → fail-open
  pg_is_agent_env || return 0                          # human push exempt (G8)
  if pg_allow_adhoc; then
    echo "zuvo pre-push: ZUVO_ALLOW_ADHOC=1 set — pipeline gate bypassed (logged)." >&2
    return 0
  fi

  local root db blocked=0 lref lsha rref rsha range rr base
  root="$(pg_repo_root 2>/dev/null)" || return 0       # no repo → fail-open
  db="$(pg_default_branch)"

  while read -r lref lsha rref rsha; do
    [ -n "${lref:-}" ] || continue
    case "$lsha" in *[!0-9a-f]*) continue ;; esac      # non-hex local sha → skip
    [ -z "${lsha//0/}" ] && continue                   # all-zero local sha = deleted ref → skip

    if [ -z "${rsha//0/}" ]; then
      # new branch (no remote tracking) → range from merge-base with default branch
      base="$(git -C "$root" merge-base "$lsha" "$db" 2>/dev/null)"
      [ -n "$base" ] || base="$(git -C "$root" rev-list --max-parents=0 "$lsha" 2>/dev/null | tail -1)"
      [ -n "$base" ] || continue
      range="$base..$lsha"
    else
      range="$rsha..$lsha"
    fi

    pg_is_substantial "$range" || continue
    pg_range_reviewed "$range"; rr=$?
    # LOCAL gate blocks only on a DEFINITIVE not-reviewed (rr==1).
    # unknown(2) fails open here — the CI gate (fail-closed) is the backstop.
    if [ "$rr" -eq 1 ]; then
      {
        echo "BLOCKED: pushing substantial unreviewed work ($range)."
        echo "  This range changes >=${ZUVO_GATE_MIN_FILES:-3} production files or >=${ZUVO_GATE_MIN_LINES:-150} lines"
        echo "  and has no covering review in memory/reviews/ (content-keyed)."
        echo "  Fix: run  zuvo:build  or  zuvo:review  on this range, then push."
        echo "       The review writes the covering artifact that unlocks the push."
        echo "  Escape (logged): ZUVO_ALLOW_ADHOC=1 git push   (use with a reason)"
        echo "  Note: the CI gate will also fail this on the PR if pushed by another path."
      } >&2
      blocked=1
    fi
  done <<EOF
$INPUT
EOF

  [ "$blocked" -eq 1 ] && return 1
  return 0
}

# ---- mode 2: PreToolUse (Claude/Codex) — content-keyed block via merge-base ---
# git-native stdin (canonical ref range) isn't available here, so we evaluate the
# branch's work as merge-base(HEAD, default)..HEAD. With the content-keyed lib this
# blocks an agent's `git push` of substantial unreviewed work on BOTH Claude and
# Codex (Codex has no Stop hook, so this is its main local block). Coverage is
# per-file-content, so already-pipeline-reviewed work + multi-agent shared branches
# pass; only genuinely unreviewed file content blocks. Falls back to the legacy
# runs.log check only when the lib is unavailable.
gate_legacy() {
  case "$INPUT" in
    *"git push"*|*"gh pr create"*) ;;
    *) return 0 ;;
  esac

  if [ "${PG_LIB_LOADED:-}" = "1" ]; then
    pg_is_agent_env || return 0          # human push exempt (G8)
    if pg_allow_adhoc; then
      echo "zuvo pre-push: ZUVO_ALLOW_ADHOC=1 set — pipeline gate bypassed (logged)." >&2
      return 0
    fi
    local range rr
    range="$(pg_mergebase_range 2>/dev/null)" || return 0   # can't compute → fail-open
    [ -n "$range" ] || return 0
    pg_is_substantial "$range" || return 0
    pg_range_reviewed "$range"; rr=$?
    if [ "$rr" -eq 1 ]; then              # definitively NOT content-reviewed → block
      {
        echo "BLOCKED: pushing substantial unreviewed work ($range)."
        echo "  Some changed production file's content has no covering review in memory/reviews/."
        echo "  Fix: run zuvo:build / zuvo:review on it (a producing pipeline writes the covering"
        echo "       artifact), OR isolate your work in a worktree so the range is clean."
        echo "  Escape (logged): ZUVO_ALLOW_ADHOC=1 git push"
        echo "  Note: the CI gate enforces the same check server-side."
      } >&2
      return 1
    fi
    return 0                              # reviewed, or unknown(2) → fail-open (CI is backstop)
  fi

  # --- legacy fallback (lib unavailable): runs.log review check ---
  local PROJECT BRANCH LOG
  PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  LOG="$HOME/.zuvo/runs.log"
  if [ ! -f "$LOG" ]; then
    echo "WARNING: No ~/.zuvo/runs.log found. Run zuvo:review before pushing for full enforcement." >&2
    return 0
  fi
  if awk -F'\t' -v proj="$PROJECT" -v branch="$BRANCH" \
    '$2 == "review" && $3 == proj && $10 == branch { found=1 } END { exit !found }' "$LOG"; then
    return 0
  fi
  echo "BLOCKED: zuvo:review not found in runs.log for ${PROJECT}/${BRANCH}." >&2
  echo "Run /review or zuvo:review before pushing." >&2
  return 1
}

# ---- dispatch --------------------------------------------------------------
if looks_native; then
  gate_native; exit $?
else
  gate_legacy; exit $?
fi
