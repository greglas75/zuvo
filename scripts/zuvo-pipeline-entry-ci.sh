#!/usr/bin/env bash
# zuvo pipeline-entry CI gate — THE GUARANTEE.
#
# Runs server-side (GitHub Actions or any CI). Unlike the local gates this is
# FAIL-CLOSED: a substantial change whose review coverage is NOT confirmed
# fails the check (exit 1). Agents cannot --no-verify or skip a server-side
# check, and the only escape (the 'zuvo:adhoc-approved' PR label) is
# human-applied — an agent cannot self-exempt.
#
# Range resolution (first match wins):
#   1. $ZUVO_CI_RANGE                       (explicit override / testing)
#   2. pull_request: merge-base(origin/$GITHUB_BASE_REF, HEAD)..HEAD
#   3. push: <before>..<after> from $GITHUB_EVENT_PATH (.before all-zeros → merge-base)
#   4. fallback: merge-base(HEAD, default-branch)..HEAD
#
# Escape: PR label 'zuvo:adhoc-approved' (via $GITHUB_EVENT_PATH labels, or the
#   $ZUVO_CI_LABELS env list for non-GitHub CI / testing).
#
# Exit: 0 = pass (not substantial / reviewed / adhoc-approved); 1 = fail.

set -uo pipefail

_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# lib lives at hooks/lib relative to repo root; the script is in scripts/.
_lib=""
for cand in "$_self_dir/../hooks/lib/pipeline-gate-lib.sh" \
            "$_self_dir/hooks/lib/pipeline-gate-lib.sh" \
            "$(pg_repo_root 2>/dev/null)/hooks/lib/pipeline-gate-lib.sh"; do
  [ -r "$cand" ] && { _lib="$cand"; break; }
done
if [ -n "$_lib" ]; then
  # shellcheck source=/dev/null
  . "$_lib"
fi

if [ "${PG_LIB_LOADED:-}" != "1" ]; then
  echo "zuvo-ci: pipeline-gate-lib.sh not found — failing CLOSED (CI is the guarantee)." >&2
  echo "         ensure hooks/lib/pipeline-gate-lib.sh is checked out (fetch-depth: 0)." >&2
  exit 1
fi

ADHOC_LABEL="${ZUVO_ADHOC_LABEL:-zuvo:adhoc-approved}"

label_adhoc() {
  case " ${ZUVO_CI_LABELS:-} " in *" $ADHOC_LABEL "*) return 0 ;; esac
  case " ${ZUVO_CI_LABELS//,/ } " in *" $ADHOC_LABEL "*) return 0 ;; esac
  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -r "${GITHUB_EVENT_PATH:-}" ] && command -v jq >/dev/null 2>&1; then
    jq -e --arg L "$ADHOC_LABEL" \
      '((.pull_request.labels // [])[]?.name) == $L' "$GITHUB_EVENT_PATH" >/dev/null 2>&1 && return 0
  fi
  return 1
}

resolve_range() {
  if [ -n "${ZUVO_CI_RANGE:-}" ]; then printf '%s' "$ZUVO_CI_RANGE"; return 0; fi
  local root db base before after
  root="$(pg_repo_root)" || return 1
  db="$(pg_default_branch)"

  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    base="$(git -C "$root" merge-base "origin/$GITHUB_BASE_REF" HEAD 2>/dev/null)"
    [ -z "$base" ] && base="$(git -C "$root" merge-base "$GITHUB_BASE_REF" HEAD 2>/dev/null)"
    [ -n "$base" ] && { printf '%s..HEAD' "$base"; return 0; }
  fi

  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -r "${GITHUB_EVENT_PATH:-}" ] && command -v jq >/dev/null 2>&1; then
    before="$(jq -r '.before // empty' "$GITHUB_EVENT_PATH" 2>/dev/null)"
    after="$(jq -r '.after // empty' "$GITHUB_EVENT_PATH" 2>/dev/null)"
    if [ -n "$after" ]; then
      if [ -z "$before" ] || [ -z "${before//0/}" ]; then
        before="$(git -C "$root" merge-base "$after" "$db" 2>/dev/null)"
      fi
      [ -n "$before" ] && { printf '%s..%s' "$before" "$after"; return 0; }
    fi
  fi

  base="$(git -C "$root" merge-base HEAD "$db" 2>/dev/null)"
  [ -n "$base" ] && { printf '%s..HEAD' "$base"; return 0; }
  return 1
}

main() {
  if label_adhoc; then
    echo "zuvo-ci: '$ADHOC_LABEL' label present — pipeline-entry gate bypassed (human-approved)."
    exit 0
  fi

  local range; range="$(resolve_range)"
  if [ -z "$range" ]; then
    echo "zuvo-ci: could not resolve the change range — failing CLOSED." >&2
    echo "         (apply the '$ADHOC_LABEL' label to override, or ensure full history is fetched.)" >&2
    exit 1
  fi
  echo "zuvo-ci: evaluating range $range"

  if ! pg_is_substantial "$range"; then
    echo "zuvo-ci: change is not substantial (< thresholds) — pass."
    exit 0
  fi

  pg_range_reviewed "$range"; local rr=$?
  if [ "$rr" -eq 0 ]; then
    echo "zuvo-ci: range is review-covered (memory/reviews/) — pass."
    exit 0
  fi

  # rr == 1 (not covered) OR rr == 2 (unknown) → FAIL CLOSED.
  {
    echo "FAILED: substantial change with no confirmed review coverage ($range)."
    echo "  This PR changes >=${ZUVO_GATE_MIN_FILES:-3} production files or >=${ZUVO_GATE_MIN_LINES:-150} lines"
    echo "  and no committed memory/reviews/ artifact covers it (content-keyed)."
    echo "  Fix: run  zuvo:build  or  zuvo:review  on this branch and push the review artifact."
    echo "  Override (human only): add the '$ADHOC_LABEL' label to this PR."
  } >&2
  exit 1
}

main "$@"
