#!/bin/sh
# refactor-gate-lib.sh — zuvo:refactor commit-boundary safety gate (core logic).
#
# The ONLY agent-independent, cross-harness bind for the refactor pipeline: a git
# hook reads the refactor CONTRACT (the artifact of record) and BLOCKS a commit/push
# whose staged/pushed files intersect an ACTIVE refactor whose Prove step is not
# recorded complete. Prose says "MANDATORY"; this makes it true regardless of which
# agent (or harness) is driving — git hooks fire for everyone.
#
# Proven by docs/specs/2026-06-30-refactor-skill-rebuild-plan.md Task 1 spike (6/6).
# POSIX sh, jq-free. Fail-OPEN by contract: callers exit 0 on any internal error so a
# broken/absent gate can NEVER brick a user's `git commit`.
#
# refactor_gate_check "<newline-separated file list>"  -> 0 allow, 1 block
#   Env:
#     ZUVO_CONTRACTS_DIR   contracts dir (default zuvo/contracts)
#     ZUVO_GATE_TTL_SEC    stale-contract bypass TTL seconds (default 86400)
#     AI-harness markers (ANY set => AI run; NONE set => human => bypass):
#                          ZUVO_AI_RUN CLAUDECODE CURSOR_TRACE_ID CODEX_SANDBOX

refactor_gate_check() {
  staged=$1
  cdir=${ZUVO_CONTRACTS_DIR:-zuvo/contracts}
  [ -d "$cdir" ] || return 0
  ttl=${ZUVO_GATE_TTL_SEC:-86400}
  blocked=0
  for c in "$cdir"/refactor-*.json; do
    [ -f "$c" ] || continue
    grep -q '"stage"[[:space:]]*:[[:space:]]*"COMPLETE"' "$c" && continue
    # intersect scope_fence with the file list.
    #  set -f: a '*'/'?' in a path must NOT glob-expand against the filesystem.
    #  grep -Fq --: fixed-string match — a '.'/'['/']' in a path is a literal, not a regex
    #  (BRE would let 'src/[i].ts' match the wrong fence entry, or fail to match its own).
    hit=0
    oldifs=$IFS; IFS='
'
    set -f
    for f in $staged; do
      [ -n "$f" ] || continue
      if grep -Fq -- "\"$f\"" "$c"; then hit=1; break; fi
    done
    set +f
    IFS=$oldifs
    [ "$hit" = 1 ] || continue
    # HUMAN BYPASS — the gate is for AI runs; never lock a human out
    if [ -z "${ZUVO_AI_RUN:-}${CLAUDECODE:-}${CURSOR_TRACE_ID:-}${CODEX_SANDBOX:-}${ANTIGRAVITY_SESSION_ID:-}" ]; then
      echo "zuvo refactor-gate: human committer (no AI-harness env) -> bypass [$c]" >&2
      continue
    fi
    # STALE BYPASS — an abandoned (crashed/timed-out) run must not block anyone
    now=$(date +%s)
    mt=$(stat -f %m "$c" 2>/dev/null || stat -c %Y "$c" 2>/dev/null || echo "$now")
    if [ $((now - mt)) -gt "$ttl" ]; then
      echo "zuvo refactor-gate: stale contract (> ${ttl}s) -> bypass [$c]" >&2
      continue
    fi
    # PROVE checks — the CONTRACT is the artifact (commit is LAST, so no fix-commit exists yet)
    ba=$(sed -n 's/.*"blind_audit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    av=$(sed -n 's/.*"adversarial"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    # characterization lock: the pin-down tests proven green on the PRE-refactor code,
    # recorded in the CONTRACT BEFORE any move edit. Prose alone was skipped in the field
    # (skill-eval 2026-07-09: CONTRACT written at PHASE-1, next touched only at prove-time)
    # — so the gate enforces the artifact, same as blind_audit/adversarial.
    ch=$(sed -n 's/.*"characterization"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$c" | head -1)
    case "$ba" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.blind_audit='$ba' not satisfied [$c]"; blocked=1 ;; esac
    case "$av" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.adversarial='$av' not satisfied [$c]"; blocked=1 ;; esac
    case "$ch" in skipped|not_run|"") echo "BLOCK: refactor CONTRACT prove.characterization='$ch' not satisfied — record the pin-down lock (tests green on PRE-refactor code) when the suite goes green, BEFORE the move [$c]"; blocked=1 ;; esac
  done
  return $blocked
}

# plan_execute_gate_check — the plan→execute bind. If an Approved plan is PENDING (execute
# never started) and the staged/pushed files intersect the plan's declared **Files:**, BLOCK:
# the work must go through `zuvo:execute`, not be hand-rolled. Fail-OPEN on any missing/odd
# input. Only `status: pending` blocks — execute flips it to `in-progress` before its commits.
plan_execute_gate_check() {
  staged=$1
  ap="${ZUVO_PLANS_DIR:-zuvo/plans}/active-plan.md"
  [ -f "$ap" ] || return 0
  # tr -d '\r' + cut at first whitespace: tolerate CRLF endings and a `pending # note` suffix
  # (otherwise `status: pending\r` != `pending` would silently fail-open — caught in review).
  st=$(sed -n 's/^status:[[:space:]]*//p' "$ap" | head -1 | tr -d '\r' | sed 's/[[:space:]].*//')
  [ "$st" = "pending" ] || return 0                                # only a pending plan blocks
  plan=$(sed -n 's/^plan:[[:space:]]*//p' "$ap" | head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')
  { [ -n "$plan" ] && [ -f "$plan" ]; } || return 0               # fail-OPEN: missing plan doc
  # `-- "$plan"` guards a leading-hyphen path; keep commas (split on them, NOT on spaces,
  # so a plan filename containing a space stays one token — caught in review).
  plan_files=$(grep '^\*\*Files:\*\*' -- "$plan" 2>/dev/null | tr -d '\r' | sed 's/^\*\*Files:\*\*//; s/`//g')
  [ -n "$(printf '%s' "$plan_files" | tr -d '[:space:]')" ] || return 0 # fail-OPEN: no **Files:**
  # HUMAN BYPASS — a human committing the plan's files is not hand-rolling AI work
  if [ -z "${ZUVO_AI_RUN:-}${CLAUDECODE:-}${CURSOR_TRACE_ID:-}${CODEX_SANDBOX:-}${ANTIGRAVITY_SESSION_ID:-}" ]; then
    echo "zuvo plan-gate: human committer (no AI-harness env) -> bypass [$ap]" >&2
    return 0
  fi
  blocked=0; oldifs=$IFS; set -f            # set -f: a '*' in a path must not glob the filesystem
  # split plan files on comma AND newline: a multi-task plan has many **Files:** lines (one per
  # task) which grep joins with newlines — comma-only IFS merged them into unmatchable tokens
  # (caught in review). Space is NOT in IFS, so a filename with a space stays one token.
  IFS=',
'
  for pf in $plan_files; do
    pf=$(printf '%s' "$pf" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')   # trim
    [ -n "$pf" ] || continue
    IFS='
'                                           # staged is newline-delimited; exact compare (no regex/glob)
    for sf in $staged; do [ "$sf" = "$pf" ] && { blocked=1; break; }; done
    IFS=',
'
    [ "$blocked" = 1 ] && break
  done
  IFS=$oldifs; set +f
  [ "$blocked" = 1 ] && echo "BLOCK: Approved plan is PENDING ($plan) — run \`zuvo:execute\`, do not hand-roll the implementation [$ap]"
  return $blocked
}
