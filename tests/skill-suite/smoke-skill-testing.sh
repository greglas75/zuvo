#!/usr/bin/env bash
# smoke-skill-testing.sh — whole-feature smoke runner for the skill-testing infra
# (Task 10). Runs the feature's end-to-end checks as SIX explicitly-named,
# individually-sectioned steps: each step prints its own header + exit code so a
# failure is attributable to exactly ONE step (adversarial WARNING rev 2). Combined
# output + a per-step summary are tee'd to zuvo/proofs/smoke-skill-testing.txt.
# Exits non-zero if any step fails.
#
# Step 1 caveat (honest, not hidden): `run-all.sh` fast scope also sweeps the
# pre-existing infra Docker e2e (tests/infra-suite/test-suite-e2e.sh), a documented
# BASELINE failure (execution-state baseline-failures + memory/backlog.md) orthogonal
# to skill-testing. A step-1 failure LIMITED to that baseline is labelled
# [KNOWN-BASELINE] and does NOT fail the feature smoke; a failure on ANYTHING else
# (including any skill-suite test) is FATAL. The real exit code is always shown.
#
# bash 3.2-compatible (macOS default): no mapfile/associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # BASH_SOURCE, not $0 (symlink-safe)
cd "$ROOT" || { echo "smoke: cannot cd to repo root '$ROOT'" >&2; exit 1; }
ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/zuvo}"
ART="$ZUVO_DIR/proofs/smoke-skill-testing.txt"   # canonical path (plan Verify checks this exact file)
RC_FILE="$(mktemp)"; printf '1' > "$RC_FILE"     # real numeric verdict (default fail); NOT a grep on stdout
trap 'rm -f "$RC_FILE"' EXIT                      # reclaim the tempfile on any signal/exit
mkdir -p "$(dirname "$ART")"

# the ONE infra test allowed to fail as a documented baseline in step 1's run-all sweep
BASELINE_INFRA="tests/infra-suite/test-suite-e2e.sh"

overall=0
SUMMARY=""

hdr() { # <n> <label> <cmd-string>
  echo "=================================================================="
  echo "=== STEP $1: $2"
  echo "=== \$ $3"
  echo "=================================================================="
}

record() { # <n> <label> <rc> [<note>]
  local n="$1" label="$2" rc="$3" note="${4:-}"
  echo "--- STEP $n EXIT=$rc ${note}"
  echo
  SUMMARY="$SUMMARY
STEP $n: $label -> EXIT=$rc ${note}"
}

run_and_report() {
  {
    echo "smoke-skill-testing — whole-feature smoke for the skill-testing infra"
    echo "run: $(date -u +%Y-%m-%dT%H:%M:%SZ)   repo: $ROOT   HEAD: $(git rev-parse --short HEAD 2>/dev/null || echo -)"
    echo

    # ── STEP 1: run-all.sh (fast scope) — with KNOWN-BASELINE handling ──────────
    hdr 1 "run-all.sh (fast scope)" "ZUVO_TEST_SCOPE=fast bash tests/run-all.sh"
    s1_out="$(ZUVO_TEST_SCOPE=fast bash tests/run-all.sh 2>&1)"; s1_rc=$?
    printf '%s\n' "$s1_out"
    if [ "$s1_rc" -eq 0 ]; then
      record 1 "run-all.sh (fast scope)" 0
    else
      # Extract failed test FILES from run-all's 'FAIL: <path> (exit N)' lines. sed (not a
      # no-space grep) so a path WITH spaces is captured whole; the ' (exit N)' suffix is
      # required so assert.sh's prose 'FAIL: <message>' lines are never mistaken for files.
      all_fails="$(printf '%s\n' "$s1_out" | sed -n 's/^FAIL: \(.*\) (exit [0-9][0-9]*).*$/\1/p' | grep -v '^$' || true)"
      # exact-LINE, fixed-string exclusion of the baseline (grep -vxF): a substring match
      # (-vF) would wrongly excuse a sibling like '<baseline>-regression.sh'.
      other_fails="$(printf '%s\n' "$all_fails" | grep -vxF -- "$BASELINE_INFRA" | grep -v '^$' || true)"
      # run-all must have RUN TO COMPLETION (its 'RESULT: PASS=' summary present) before we
      # excuse the baseline — else a crash AFTER the baseline failed early (all_fails=[baseline])
      # would be masked. No summary + non-zero exit = fatal, never KNOWN-BASELINE.
      completed=0; printf '%s\n' "$s1_out" | grep -qE '^RESULT: PASS=' && completed=1
      if [ "$completed" -eq 1 ] && [ -n "$all_fails" ] && [ -z "$other_fails" ]; then
        record 1 "run-all.sh (fast scope)" "$s1_rc" "[KNOWN-BASELINE: only $BASELINE_INFRA failed — pre-existing infra Docker e2e, backlogged; NOT a skill-testing regression]"
      else
        if [ "$completed" -eq 0 ]; then
          reason="<run-all did not print its RESULT summary — crashed/timed-out, not tolerated>"
        else
          reason="${other_fails:-<non-zero exit with no attributable FAIL lines>}"
        fi
        record 1 "run-all.sh (fast scope)" "$s1_rc" "[FATAL: $(printf '%s' "$reason" | tr '\n' ' ')]"
        overall=1
      fi
    fi

    # ── STEPS 2-6: skill-testing feature checks (any non-zero is FATAL) ─────────
    for spec in \
      "2|validate-skills.sh structural lint|scripts/validate-skills.sh" \
      "3|test-infra-wiring.sh|tests/infra-suite/test-infra-wiring.sh" \
      "4|test-dev-push-gate.sh (fence branch behavior)|tests/skill-suite/test-dev-push-gate.sh" \
      "5|test-eval-corpus-schema.sh|tests/skill-suite/test-eval-corpus-schema.sh" \
      "6|test-skill-eval-skill-contract.sh|tests/skill-suite/test-skill-eval-skill-contract.sh"; do
      n="${spec%%|*}"; rest="${spec#*|}"; label="${rest%%|*}"; file="${rest##*|}"
      hdr "$n" "$label" "bash $file"
      bash "$file"; rc=$?
      record "$n" "$label" "$rc"
      [ "$rc" -eq 0 ] || overall=1
    done

    echo "=================================================================="
    echo "SUMMARY (6 named steps):$SUMMARY"
    echo "=================================================================="
    echo "OVERALL EXIT=$overall"
    # persist the REAL numeric verdict to a file (the block runs in a subshell because of
    # the tee pipe, so `overall` can't propagate via a variable). This is the authoritative
    # exit source — NOT a grep for 'OVERALL EXIT=0' in the artifact, which any inner test
    # printing that string could spoof.
    printf '%s' "$overall" > "$RC_FILE"
  } 2>&1 | tee "$ART"
}

run_and_report

rc="$(cat "$RC_FILE" 2>/dev/null || echo 1)"
rm -f "$RC_FILE"
case "$rc" in 0) exit 0 ;; *) exit 1 ;; esac
