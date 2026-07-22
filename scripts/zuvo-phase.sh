#!/bin/sh
# zuvo-phase.sh — is the plan→execute gate actually ARMED in this repo?
#
# The gate (hooks/lib/refactor-gate-lib.sh :: plan_execute_gate_check) reads
# zuvo/plans/active-plan.md. If it cannot parse that file it fail-OPENs — silently. That is not
# hypothetical: the canonical template in shared/includes/session-state.md documented the
# `<!-- status: -->` dialect while the gate only read a plain `status:` line, so 8 of 19 live
# repos had a completely dead gate and nothing said so. This script is the missing feedback
# loop: it answers "can the gate read my state?" instead of leaving it to be discovered by a
# hand-rolled commit sailing through.
#
#   zuvo-phase.sh status            what the gate SEES here (fields, dialect, evidence)
#   zuvo-phase.sh doctor            verdict for this repo: ARMED / BLIND / IDLE
#   zuvo-phase.sh doctor --all      sweep the fleet (ZUVO_PHASE_ROOTS, default ~/DEV/*)
#   zuvo-phase.sh normalize         show what a one-dialect rewrite would change (diff only)
#   zuvo-phase.sh normalize --write apply it
#
# Read-only except `normalize --write`. Exit: 0 healthy, 1 a real problem, 2 usage.
#
# It deliberately does NOT re-implement the parser — it sources the gate's own lib, so the
# doctor and the gate can never disagree about what a file says. That shared-parser rule is the
# whole point; a second parser would just recreate the drift this exists to detect.
set -u

# Sibling-lib lookup: `scripts/` and `hooks/lib/` are siblings in a git checkout AND in every
# installed dist (install.sh copies scripts/*.sh flat and hooks/ recursively under one root).
# Same candidate-list shape as scripts/zuvo-pipeline-entry-ci.sh.
_self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
_lib=""
for _cand in "$_self_dir/../hooks/lib/refactor-gate-lib.sh" \
             "$_self_dir/hooks/lib/refactor-gate-lib.sh" \
             "${ZUVO_PLUGIN_ROOT:-}/hooks/lib/refactor-gate-lib.sh"; do
  [ -r "$_cand" ] && { _lib="$_cand"; break; }
done
[ -n "$_lib" ] || { echo "zuvo-phase: refactor-gate-lib.sh not found — cannot report on a parser I can't load." >&2; exit 1; }
# shellcheck source=/dev/null
. "$_lib"

PLANS_DIR="${ZUVO_PLANS_DIR:-zuvo/plans}"

# ---------------------------------------------------------------------------
# inspect <repo_root> — echo one TSV row: verdict status dialect plan nfiles evidence
# Verdicts:
#   ARMED  gate can read the pointer and would act on it
#   BLIND  a pointer exists but the gate cannot read status or plan -> silent fail-open
#   IDLE   no pointer, or a terminal status: nothing to gate (not a fault)
# ---------------------------------------------------------------------------
inspect() {
  _root=$1
  _ap="$_root/$PLANS_DIR/active-plan.md"
  [ -f "$_ap" ] || { printf 'IDLE\t-\t-\t-\t0\tno active-plan.md\n'; return; }

  _st=$(_ap_status "$_ap")
  _plan=$(_ap_plan "$_ap")

  # Which dialect produced the status? (plain line vs HTML comment vs neither)
  if sed -n 's/^status:[[:space:]]*//p' "$_ap" 2>/dev/null | head -1 | grep -q .; then
    _dia=plain
  elif [ -n "$_st" ]; then
    _dia=comment
  else
    _dia=unreadable
  fi
  # `plan_file:` alias is worth surfacing — it is why one real repo parsed as empty.
  if [ -z "$(_ap_field "$_ap" plan)" ] && [ -n "$(_ap_field "$_ap" plan_file)" ]; then
    _dia="$_dia+plan_file"
  fi

  if [ -z "$_st" ] || [ -z "$_plan" ]; then
    printf 'BLIND\t%s\t%s\t%s\t0\tgate parses %s\n' \
      "${_st:--}" "$_dia" "${_plan:--}" \
      "$([ -z "$_st" ] && echo 'no status' || echo 'no plan path')"
    return
  fi

  case "$_st" in
    pending|in-progress) ;;
    *) printf 'IDLE\t%s\t%s\t%s\t0\tterminal status — nothing to gate\n' "$_st" "$_dia" "$_plan"; return ;;
  esac

  # A readable pointer whose plan doc is gone can never gate anything (fail-open by design).
  if [ ! -f "$_root/$_plan" ] && [ ! -f "$_plan" ]; then
    printf 'BLIND\t%s\t%s\t%s\t0\tplan doc missing on disk\n' "$_st" "$_dia" "$_plan"
    return
  fi
  _pd="$_root/$_plan"; [ -f "$_pd" ] || _pd="$_plan"
  _n=$(_expand_plan_files "$_pd" | grep -c . 2>/dev/null || echo 0)
  [ "$_n" -gt 0 ] 2>/dev/null || {
    printf 'BLIND\t%s\t%s\t%s\t0\tplan declares no **Files:** — gate fail-opens\n' "$_st" "$_dia" "$_plan"; return; }

  _ev="-"
  if [ "$_st" = "in-progress" ]; then
    # Same arguments the gate uses, so the doctor cannot report "live" where the gate would not.
    if _execute_run_live "$_root" "$_plan"; then _ev="live execute run"
    else _ev="STALE: in-progress with no execute evidence (will gate as pending)"; fi
  fi
  printf 'ARMED\t%s\t%s\t%s\t%s\t%s\n' "$_st" "$_dia" "$_plan" "$_n" "$_ev"
}

repo_root() { git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null; }

cmd_status() {
  _root=$(repo_root .) || _root=""
  [ -n "$_root" ] || { echo "zuvo-phase: not a git repository." >&2; exit 1; }
  _row=$(inspect "$_root")
  echo "repo:      $_root"
  echo "pointer:   $_root/$PLANS_DIR/active-plan.md"
  echo "verdict:   $(printf '%s' "$_row" | cut -f1)"
  echo "status:    $(printf '%s' "$_row" | cut -f2)   (dialect: $(printf '%s' "$_row" | cut -f3))"
  echo "plan:      $(printf '%s' "$_row" | cut -f4)"
  echo "files:     $(printf '%s' "$_row" | cut -f5) path(s) declared by **Files:**"
  echo "evidence:  $(printf '%s' "$_row" | cut -f6)"
}

cmd_doctor_one() {
  _root=$(repo_root .) || _root=""
  [ -n "$_root" ] || { echo "zuvo-phase: not a git repository." >&2; exit 1; }
  echo "PLAN-GATE DOCTOR — can hooks/lib/refactor-gate-lib.sh read this repo's state?"
  _row=$(inspect "$_root")
  _v=$(printf '%s' "$_row" | cut -f1)
  printf '  %-14s %s (status=%s dialect=%s files=%s)\n' "$(basename "$_root")" "$_v" \
    "$(printf '%s' "$_row" | cut -f2)" "$(printf '%s' "$_row" | cut -f3)" "$(printf '%s' "$_row" | cut -f5)"
  printf '  %-14s %s\n' "" "$(printf '%s' "$_row" | cut -f6)"
  echo "  ---"
  case "$_v" in
    ARMED) echo "  gate is ARMED"; return 0 ;;
    IDLE)  echo "  nothing to gate (no pending/in-progress plan) — not a fault"; return 0 ;;
    *)     echo "  gate is BLIND — it will fail-open on every commit until the pointer is readable."
           echo "  fix: zuvo-phase.sh normalize --write   (rewrites the pointer in the dialect the gate reads)"
           return 1 ;;
  esac
}

cmd_doctor_all() {
  # Fleet sweep. Same convention as ~/.zuvo/backlog-collect.py: colon-separated globs.
  _roots="${ZUVO_PHASE_ROOTS:-$HOME/DEV/*}"
  echo "PLAN-GATE DOCTOR — fleet sweep ($_roots)"
  _armed=0; _blind=0; _idle=0
  _oldifs=$IFS; IFS=':'
  for _pat in $_roots; do
    # $_pat is ALREADY a concrete path: `for _pat in $_roots` field-splits on ':' and then
    # pathname-expands each field, and glob results are never re-split — so a directory named
    # `My Project` arrives here intact. Do NOT expand it a second time. The original
    # `set -f; set +f -- $_pat` + `for _d in "$@"` did exactly that under the restored default
    # IFS, splitting the resolved path on its space into two nonexistent paths: the repo
    # vanished from the sweep entirely, counted in neither armed, blind, nor idle. Silent
    # omission is the one failure mode a diagnostic must never have.
    _d=$_pat
    IFS=$_oldifs
    # -e, NOT -d: in a linked worktree `.git` is a FILE. `-d` silently skipped 6 of this
    # machine's worktrees that DO carry an active-plan.md.
    if [ -e "$_d/.git" ]; then
      _row=$(inspect "$_d")
      _v=$(printf '%s' "$_row" | cut -f1)
      # No `continue` here: it would skip the IFS=':' reset below and break the split for
      # every remaining pattern. IDLE repos are counted but not printed (noise in a sweep).
      case "$_v" in
        ARMED) _armed=$((_armed+1)) ;;
        BLIND) _blind=$((_blind+1)) ;;
        *)     _idle=$((_idle+1)) ;;
      esac
      case "$_v" in
        ARMED|BLIND)
          printf '  %-8s %-34s status=%-12s dialect=%-16s %s\n' \
            "$_v" "$(basename "$_d")" "$(printf '%s' "$_row" | cut -f2)" \
            "$(printf '%s' "$_row" | cut -f3)" "$(printf '%s' "$_row" | cut -f6)" ;;
      esac
    fi
    IFS=':'
  done
  IFS=$_oldifs
  echo "  ---"
  echo "  armed: $_armed   blind: $_blind   idle/none: $_idle"
  [ "$_blind" -eq 0 ] && return 0 || return 1
}

# normalize — rewrite the pointer into the ONE dialect the gate reads (plain `status:`/`plan:`),
# preserving every other line. Prints a diff; only touches disk with --write.
cmd_normalize() {
  _write=${1:-}
  _root=$(repo_root .) || _root=""
  [ -n "$_root" ] || { echo "zuvo-phase: not a git repository." >&2; exit 1; }
  _ap="$_root/$PLANS_DIR/active-plan.md"
  [ -f "$_ap" ] || { echo "zuvo-phase: no $PLANS_DIR/active-plan.md — nothing to normalize."; return 0; }
  # A temp-file + mv replaces the DIRECTORY ENTRY, so normalizing a symlinked pointer would
  # leave the real target untouched and orphaned while silently turning the link into a regular
  # file. Refuse rather than quietly break a shared/worktree symlink setup.
  [ -L "$_ap" ] && { echo "zuvo-phase: $_ap is a symlink — refusing to normalize (mv would replace the link, not its target)." >&2; return 1; }
  _st=$(_ap_status "$_ap"); _plan=$(_ap_plan "$_ap")
  if [ -z "$_st" ] || [ -z "$_plan" ]; then
    echo "zuvo-phase: cannot normalize — status=[${_st:--}] plan=[${_plan:--}]." >&2
    echo "  Neither dialect yielded both fields; fix the file by hand:" >&2
    echo "    status: pending|in-progress|completed" >&2
    echo "    plan: <path to the plan doc>" >&2
    return 1
  fi
  _tmp="$_ap.zuvo-phase.$$"
  # Drop any existing status/plan/plan_file line in either dialect, keep everything else, then
  # write the canonical pair at the top.
  {
    printf '# Active Plan\n'
    printf 'status: %s\n' "$_st"
    printf 'plan: %s\n' "$_plan"
    sed -e '/^status:/d' -e '/^plan:/d' -e '/^plan_file:/d' \
        -e '/^[[:space:]]*<!--[[:space:]]*status:/d' \
        -e '/^[[:space:]]*<!--[[:space:]]*plan:/d' \
        -e '/^#[[:space:]]*Active Plan/d' "$_ap"
  } > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; echo "zuvo-phase: write failed." >&2; return 1; }
  if diff -u "$_ap" "$_tmp" >/dev/null 2>&1; then
    echo "zuvo-phase: already canonical — no change."; rm -f "$_tmp"; return 0
  fi
  diff -u "$_ap" "$_tmp" 2>/dev/null | sed 's/^/  /'
  if [ "$_write" = "--write" ]; then
    # $_tmp was created fresh, so it carries umask-derived permissions; mv keeps the SOURCE's
    # mode. Without this a mode-400 pointer silently becomes 644.
    chmod --reference="$_ap" "$_tmp" 2>/dev/null \
      || chmod "$(stat -f %Lp "$_ap" 2>/dev/null || stat -c %a "$_ap" 2>/dev/null || echo 644)" "$_tmp" 2>/dev/null
    mv "$_tmp" "$_ap" && echo "zuvo-phase: normalized $_ap"
  else
    rm -f "$_tmp"; echo "zuvo-phase: dry run — re-run with --write to apply."
  fi
}

case "${1:-status}" in
  status)    cmd_status ;;
  doctor)    if [ "${2:-}" = "--all" ]; then cmd_doctor_all; else cmd_doctor_one; fi ;;
  normalize) cmd_normalize "${2:-}" ;;
  -h|--help|help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "zuvo-phase: unknown command '${1:-}' (status | doctor [--all] | normalize [--write])" >&2; exit 2 ;;
esac
