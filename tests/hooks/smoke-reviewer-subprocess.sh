#!/usr/bin/env bash
#
# smoke-reviewer-subprocess.sh — Plan A whole-feature smoke: the shared reviewer runner
# (scripts/lib/model-subprocess.sh) end to end. It chains the plan's three smoke proofs
# (docs/specs/2026-09-25-reviewer-subprocess-foundation-plan.md, "Whole-feature Smoke Proofs"),
# each command exactly as the plan's Proof line states it:
#   SMOKE-A1  the adversarial codex/claude lanes are unchanged by the extraction (golden replay);
#   SMOKE-A2  the router still prints its six keys with an EMPTY PATH (library resolved by path,
#             clients gone → same-model-fallback, never the missing-library sentinel);
#   SMOKE-A3  an echoing client cannot pass a preflight canary, and an INSTALLED driver loads the
#             installed library.
# Every referenced script must exist before its link runs (a missing one is a failed link, not a
# skipped one). Exit 0 only when every link passed AND at least one check actually executed — a
# smoke whose links all vanished must not read as green.
#
# Named smoke-* on purpose: run-all.sh globs tests/hooks/test-*.sh, which already runs the suites
# chained here; this file would only run them a second time.
#
# Run (bash 3.2 and 5.x):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-reviewer-subprocess.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/smoke-reviewer-subprocess.sh
# The chained suites run under `bash` from PATH, as the Proof lines say; SMOKE-A2 pins /bin/bash
# itself. No real model CLI runs: every chained suite is hermetic (spies, temp HOME, env -i).
#
# SOURCEABLE: tests/hooks/test-smoke-reviewer-subprocess.sh sources this file to test link(),
# suite() and smoke_verdict() on synthetic inputs. Only a DIRECT run (`bash <this file>`) merges
# stderr, runs the four links and exits with the verdict; sourcing defines the harness and stops.
set -u
_SMOKE_MAIN=0
[ "${BASH_SOURCE[0]:-$0}" = "$0" ] && _SMOKE_MAIN=1
# One ordered stream: the output is a proof log (zuvo/proofs/smoke-plan-a.txt), and a chained
# suite's stderr belongs next to the link that produced it.
if [ "$_SMOKE_MAIN" -eq 1 ]; then exec 2>&1; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
# The Proof lines use repo-relative paths (SMOKE-A2 runs `scripts/reviewer-model-route.sh`).
cd "$ROOT" || { echo "smoke: cannot cd to $ROOT" >&2; exit 2; }

EXECUTED=0; PASSED=0; FAILED=0

# link <id> <what it proves> <verdict function> <repo-relative file the link needs>...
link() {
  local id="$1" what="$2" fn="$3" f rc
  shift 3
  echo "=== $id — $what ==="
  for f in "$@"; do
    if [ ! -f "$ROOT/$f" ]; then
      echo "  FAIL $id: required file $f is missing — link not run"
      FAILED=$((FAILED+1))
      return 0
    fi
  done
  EXECUTED=$((EXECUTED+1))
  "$fn"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  PASS $id (exit 0)"
    PASSED=$((PASSED+1))
  else
    echo "  FAIL $id (exit $rc)"
    [ "$id" = "SMOKE-A2" ] && echo "    (the verdict is awk's; re-run the Proof line without the awk to see what the router printed)"
    FAILED=$((FAILED+1))
  fi
  return 0
}

# suite <path> — run a chained suite and demand proof of work: exit 0 alone would also be the
# verdict of a suite that skipped every case or exited early. It must report at least one PASS and
# no FAIL line of its own (all chained suites print `PASS …` / `FAIL …` per assertion).
suite() {
  local out rc np nf
  out="$(mktemp "${TMPDIR:-/tmp}/smoke-suite.XXXXXX")" || { echo "  smoke: mktemp failed"; return 2; }
  bash "$1" > "$out" 2>&1
  rc=$?
  cat "$out"
  np="$(awk '/^[[:space:]]*PASS[: ]/ {n++} END {print n+0}' "$out")"
  nf="$(awk '/^[[:space:]]*FAIL[: ]/ {n++} END {print n+0}' "$out")"
  rm -f "$out"
  [ "$rc" -eq 0 ] || return "$rc"
  if [ "$np" -eq 0 ] || [ "$nf" -ne 0 ]; then
    echo "  smoke: $1 exited 0 but reported PASS=$np FAIL=$nf — no proof of work"
    return 3
  fi
  return 0
}

smoke_a1() {
  suite tests/hooks/test-adversarial-lane-golden.sh
}

# Verbatim from the plan (SMOKE-A2); its verdict is awk's exit status — with pipefail, so a router
# that crashed after printing six lines cannot pass on awk's word alone. The subshell keeps the
# option local.
smoke_a2() (
  set -o pipefail
  env -u CLAUDECODE -u CLAUDE_MODEL -u CODEX_SANDBOX -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier -u ZUVO_CODEX_MODEL -u CODEX_MODEL -u ANTIGRAVITY_SESSION_ID VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5-fast PATH=/nonexistent /bin/bash scripts/reviewer-model-route.sh | awk -F= '{k[$1]++; n++} $1=="routing_status"{s=$2} END{exit !(n==6 && k["platform"]==1 && k["writer_model"]==1 && k["writer_lane"]==1 && k["reviewer_lane"]==1 && k["reviewer_model"]==1 && k["routing_status"]==1 && s=="same-model-fallback")}'
)

smoke_a3_preflight() {
  suite tests/hooks/test-reviewer-preflight-isolation.sh
}

smoke_a3_install() {
  suite tests/hooks/test-install-wiring.sh
}

# smoke_verdict — the final verdict from the counters; EXITS (1 on any failure or when nothing ran).
smoke_verdict() {
  echo "=== RESULT ==="
  echo "RESULT: EXECUTED=$EXECUTED PASS=$PASSED FAIL=$FAILED"
  if [ "$EXECUTED" -eq 0 ]; then
    echo "SMOKE FAIL: no check executed"
    exit 1
  fi
  if [ "$FAILED" -ne 0 ]; then
    echo "SMOKE FAIL"
    exit 1
  fi
  echo "SMOKE PASS"
  exit 0
}

if [ "$_SMOKE_MAIN" -eq 1 ]; then
  link "SMOKE-A1" "adversarial lanes unchanged after the extraction" smoke_a1 \
    tests/hooks/test-adversarial-lane-golden.sh scripts/adversarial-review.sh scripts/lib/model-subprocess.sh
  link "SMOKE-A2" "router answers with six keys under PATH=/nonexistent (same-model-fallback)" smoke_a2 \
    scripts/reviewer-model-route.sh scripts/lib/model-subprocess.sh
  link "SMOKE-A3a" "an echoing client cannot pass a preflight canary" smoke_a3_preflight \
    tests/hooks/test-reviewer-preflight-isolation.sh scripts/reviewer-preflight.sh
  link "SMOKE-A3b" "an installed driver loads the installed library" smoke_a3_install \
    tests/hooks/test-install-wiring.sh scripts/install.sh scripts/lib/model-subprocess.sh
  smoke_verdict
fi
