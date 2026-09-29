#!/usr/bin/env bash
#
# smoke-blind-audit.sh — Plan B (blind coverage audit as a panel), Task 10: the whole-feature smoke
# proof, SMOKE-B1 + SMOKE-B2 of docs/specs/2026-09-25-blind-audit-panel-plan.md.
#
# Named `smoke-*` on purpose: tests/run-all.sh globs `test-*.sh`, not this file, so it never joins
# the default suite. Run it directly:
#   TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-blind-audit.sh                      # SMOKE-B1 only
#   TF_ALLOW_LOCAL=1 ZUVO_LIVE_SMOKE=1 bash tests/hooks/smoke-blind-audit.sh    # + SMOKE-B2 (real CLIs)
#
# SMOKE-B1 (always runs, fully hermetic — every driver/hook call under `env -i` with an explicit
# minimal environment, like tests/hooks/test-adversarial-blind-audit.sh's drive(), never this
# process's own PATH/TMPDIR/ZUVO_*): the 3-mock strict run end to end (merged block, adversarial.log
# rows naming the mocks, MOCK_CALL_LOG proving the call count), the post-skill hook still nagging
# when the only adversarial.log rows are blind-audit ones, the echo/one-valid/none-valid/oversize
# edges. B1.7-B1.10 then pin SMOKE-B2's OWN judgement logic (the live-log bookkeeping, the
# excused-outage rule, B2.4's row scan, B2.5's effort scan) on fixed inputs, so none of it is code that
# only a costly live run ever executes.
#
# SMOKE-B2 (only with ZUVO_LIVE_SMOKE=1): ONE real run of the repo driver against real model CLIs,
# pinned agy + codex-5.3. Host-aware WITHOUT reimplementing host detection AND without ever passing
# vacuously (S1, Plan B Task 10 review round 3): the host comes from the driver's OWN stderr — the
# "Host detected: <h> -- ..." line `--list-providers --mode blind-audit` prints before any mode
# branch runs (verified live, not assumed) — never a re-extracted/eval'd copy of
# detect_host_platform() and never a re-typed copy of its lane->vendor case. bap_vendor_excluded(<h>)
# (the sourced scripts/lib/blind-audit-panel.sh) then gives the excluded-lane set the expected pins
# and the "no host-vendor lane" checks both key off. An independent oracle (CLAUDECODE set -> host
# MUST be claude) and a "detection failed or the excluded set is empty is always a FAIL" rule keep
# this from ever passing on a host that was not actually detected. Never conflated with "not
# installed" (which --list-providers's candidate list alone cannot distinguish from "host-excluded"
# — a machine with agy simply not logged in would silently pass a candidate-list-derived pin check).
#
# Exit contract: 0 every executed part passed; 75 the live panel got < 2 valid answers AND the driver
# exited non-zero AND >= 1 provider outcome was non-ok AND every non-ok outcome is infra
# (timeout/auth/quota — an outage, not a code bug; `empty`, `invalid` and any other outcome never
# are, see live_outcomes_excused; an all-`ok` panel with < 2 valid, e.g. only one lane survived
# exclusion/allowlisting, has ZERO non-ok outcomes and so is NEVER excused); 1 anything else. Every
# executed PASS/FAIL check appends one line to zuvo/proofs/smoke-plan-b.txt (truncated at the top of
# this run); an N/A (no pin legitimately expected on this host, no codex lane in this panel) prints a
# NOTE line instead and is never counted as executed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
cd "$ROOT" || { echo "FAIL: cannot cd to repo root $ROOT"; exit 1; }

AR="$ROOT/scripts/adversarial-review.sh"
LIB="$ROOT/scripts/lib/blind-audit-panel.sh"
MOCKS="$ROOT/tests/adversarial/mocks"
FXLIVE="$ROOT/tests/hooks/fixtures/blind-audit-live"
HOOK="${ZUVO_TEST_HOOK:-$ROOT/hooks/post-skill-adversarial-check.sh}"

PROOF_DIR="$ROOT/zuvo/proofs"
PROOF="$PROOF_DIR/smoke-plan-b.txt"
mkdir -p "$PROOF_DIR"
: > "$PROOF"

EXECUTED=0
FAILED=0

# record <PASS|FAIL> <name> <evidence...> — one proof line, also echoed to our own stdout. Counted.
record() {
  local status="$1" name="$2"; shift 2
  local ev="$*"
  EXECUTED=$((EXECUTED + 1))
  if [ "$status" != PASS ]; then FAILED=$((FAILED + 1)); fi
  ev="$(printf '%s' "$ev" | tr '\n\t' '  ')"
  if [ "${#ev}" -gt 400 ]; then ev="${ev:0:400}…"; fi
  printf '%s\t%s\t%s\n' "$status" "$name" "$ev" >> "$PROOF"
  echo "  $status $name — $ev"
}

# note <name> <evidence...> — an N/A: printed and logged for traceability, but NEVER counted as an
# executed check (F4) — a machine without a codex lane in the panel, or a host that excludes neither
# pin, proves nothing either way and must not inflate the executed count with a vacuous pass.
note() {
  local name="$1"; shift
  local ev="$*"
  ev="$(printf '%s' "$ev" | tr '\n\t' '  ')"
  printf 'NOTE\t%s\t%s\n' "$name" "$ev" >> "$PROOF"
  echo "  NOTE $name — $ev"
}

# Precondition failures are recorded too (F10) — a reader of the proof file must see WHY nothing
# else ran, not just an empty file next to a bare exit 1.
[ -f "$AR" ]  || { record FAIL "precondition: driver present" "not found: $AR"; exit 1; }
[ -f "$LIB" ] || { record FAIL "precondition: panel library present" "not found: $LIB"; exit 1; }
[ -f "$HOOK" ] || { record FAIL "precondition: post-skill hook present" "not found: $HOOK"; exit 1; }
[ -f "$FXLIVE/sum.sh" ] && [ -f "$FXLIVE/sum.test.sh" ] \
  || { record FAIL "precondition: live fixtures present" "missing under $FXLIVE"; exit 1; }
command -v jq >/dev/null 2>&1 || { record FAIL "precondition: jq available" "jq not found on PATH"; exit 1; }

# The panel library is sourced once, here: safe under our own `set -uo pipefail` by its own contract
# (nothing external runs at source time, no shell option/trap of ours is touched) — gives us
# bap_vendor_excluded for both F2 (expected pins) and F3 (no host-vendor lane) in SMOKE-B2, the
# driver's real vendor-exclusion table, never a re-guess of it.
# shellcheck source=scripts/lib/blind-audit-panel.sh
. "$LIB"

# ═══════════════════════════════════════════════════════════════════════════
# SMOKE-B2's judgement logic, as functions: SMOKE-B2 calls them on the live panel's output, and
# B1.7-B1.10 call them on fixed inputs — so a mistake in them fails every mock run, not only the rare
# live one.
# ═══════════════════════════════════════════════════════════════════════════

# live_adv_log_path — the adversarial.log a live dispatch appends to (the driver's own default path).
live_adv_log_path() { printf '%s\n' "${ZUVO_HOME:-$HOME/.zuvo}/adversarial.log"; }

# adv_log_rows <file> — its row count, READ-ONLY. Prints nothing (status 1) when the file is absent or
# cannot be counted: never a defaulted 0, which is indistinguishable from a real empty log. Rows, not
# newlines (`wc -l`): a writer killed mid-append leaves a last row with no newline, and it counts.
adv_log_rows() {
  local n
  [ -f "${1:-}" ] || return 1
  n="$(awk 'END { print NR }' 2>/dev/null < "$1")" || return 1
  n="${n//[[:space:]]/}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

# adv_log_growth <file> <pre-count> — ONE diagnostic line: how far <file> grew since <pre-count> (from
# adv_log_rows; "" when that count failed). READ-ONLY by contract (P2-42): the live log is the
# developer's REAL, SHARED ~/.zuvo/adversarial.log, and rows appended while the panel ran cannot be
# told apart from a concurrent run's — so nothing in this script ever rewrites, trims or truncates it.
# The rows the live panel leaves behind are blind-audit rows (column 3 `blind-audit`), which no
# review-coverage gate counts (docs/adversarial-providers.md): clutter, never evidence.
adv_log_growth() {
  local post pre="${2:-}"
  case "$pre" in
    ''|*[!0-9]*) printf '%s\n' "$1: no pre-run row count — growth not measured; the log is left untouched"; return 0 ;;
  esac
  if ! post="$(adv_log_rows "$1")"; then
    printf '%s\n' "$1: no post-run row count (pre=$pre) — growth not measured; the log is left untouched"; return 0
  fi
  if [ "$post" -lt "$pre" ]; then   # never a negative "appended": only another process can shrink it
    printf '%s\n' "$1: log shrank by $((pre - post)) row(s) while the panel ran — likely truncated by another process; left untouched"; return 0
  fi
  printf '%s\n' "$1: $((post - pre)) row(s) appended while the panel ran (its blind-audit rows plus any concurrent writer's) — left in place, never trimmed"
}

# live_outcomes_excused <outcomes> <valid-count> <driver-rc> — status 0 when a live panel with fewer
# than 2 valid answers is an EXCUSED infra outage (exit 75): the driver exited non-zero (0 means strict,
# which needs >= 2 valid — ADV-B66), >= 1 outcome is non-ok (an all-`ok` panel with < 2 valid, e.g. one
# lane left after exclusion/allowlisting, is never excused — F1/S8), and EVERY non-ok outcome is infra:
# timeout, auth, quota — an allowlist of the driver's own vocabulary (ok|timeout|auth|quota|empty|
# unverified|no-runner|not-attempted, adversarial-review.sh's adversarial.log column note, plus
# blind-audit's `invalid`), so any other or unknown word is never excused. `invalid` is not (a model
# misreading the protocol), `unverified`/`no-runner` are not (a broken install), and neither is
# `empty` (P2-63): it is the driver's catch-all for a lane that produced no answer and was not
# classified as a timeout, an auth stub, a quota limit or a missing runner (adversarial-review.sh's
# result-collection loop) — which is also exactly what a CLI rejecting the argv the driver built looks
# like, the code regression this live smoke exists to catch — and `--json` carries no per-lane exit
# code or stderr that could tell the two apart. Each token is CR-stripped and trimmed first (S5):
# "timeout " or "timeout\r" must classify as timeout.
live_outcomes_excused() {
  local outcomes="${1:-}" valid_n="${2:-}" rc="${3:-}" lines _entry _oc non_ok=0 all_infra=1
  case "$valid_n" in ''|*[!0-9]*) return 1 ;; esac
  case "$rc" in ''|*[!0-9]*) return 1 ;; esac
  lines="$(printf '%s' "$outcomes" | tr -d '\r' | tr ',' '\n')"
  while IFS= read -r _entry; do
    _entry="${_entry#"${_entry%%[![:space:]]*}"}"; _entry="${_entry%"${_entry##*[![:space:]]}"}"
    [ -n "$_entry" ] || continue
    _oc="${_entry#*:}"
    _oc="${_oc#"${_oc%%[![:space:]]*}"}"; _oc="${_oc%"${_oc##*[![:space:]]}"}"
    [ "$_oc" = ok ] && continue
    non_ok=1
    case "$_oc" in timeout|auth|quota) ;; *) all_infra=0 ;; esac
  done <<< "$lines"
  [ "$valid_n" -lt 2 ] && [ "$rc" -ne 0 ] && [ "$non_ok" = 1 ] && [ "$all_infra" = 1 ]
}

# b24_scan <merged-block> <guard-start> <guard-end> — B2.4's reading of the merged table for the
# guard's line range, into globals: B24_RESULT gap|nogap|nooverlap; B24_ROW/B24_COV the first GAP row
# and its coverage cell (else the first overlapping row); B24_TABLE the table rows seen, one per line.
#   - EVERY row whose production lines overlap the range is examined (P2-60): a FULL row first does
#     not hide a later gap row over the same lines.
#   - "production lines" may hold several comma-separated sub-ranges ("5, 9-12") with any spacing
#     around the dash ("7 - 10"); each is overlap-tested on its OWN, never the outer span (S3), and a
#     reversed one ("12-5", model-written text) is read in order first, so it cannot miss an overlap.
#   - Coverage is read only from a row with all 7 cells: >= 9 fields split on '|' (P2-46). A '|' inside
#     test evidence or notes adds fields AFTER coverage and moves nothing before it (bap_merge rejoins
#     such extra cells into notes), so coverage is field 6 — but a short row has no coverage cell, and
#     an overlapping short row reads as coverage "" (not a gap), never as whatever field 6 happens to be.
#   - A gap is a coverage cell that is non-empty and, normalised the way bap_merge normalises it (case,
#     `*`/backticks, blanks), neither FULL nor N/A (ADV-B46/P2-46): a "**full**" cell is not a gap. Like
#     bap_merge, a cell off the protocol's closed scale — "FULL (manual)" — IS one: never read as FULL.
b24_scan() {
  local merged="${1:-}" g_start="${2:-}" g_end="${3:-}" _row _pl _cov _norm _sr _rs _re _pl_hit _nf
  local -a _subranges
  B24_RESULT=nooverlap; B24_ROW=""; B24_COV=""
  B24_TABLE="$(printf '%s\n' "$merged" | awk '
      $0 == "| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |" { intab = 1; next }
      intab && /^\|/ { if ($0 !~ /^\|[-:| ]+\|?$/) print; next }
      intab && $0 == "" { exit }
    ')"
  case "$g_start" in ''|*[!0-9]*) return 0 ;; esac
  case "$g_end" in ''|*[!0-9]*) return 0 ;; esac
  while IFS= read -r _row; do
    [ -n "$_row" ] || continue
    _pl="$(printf '%s' "$_row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4 }')"
    [ -n "$_pl" ] || continue
    _pl_hit=0
    IFS=',' read -ra _subranges <<< "$_pl"
    for _sr in ${_subranges[@]+"${_subranges[@]}"}; do
      _sr="$(printf '%s' "$_sr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]*-[[:space:]]*/-/')"
      case "$_sr" in
        *-*) _rs="${_sr%%-*}"; _re="${_sr##*-}" ;;
        *)   _rs="$_sr"; _re="$_sr" ;;
      esac
      case "$_rs" in ''|*[!0-9]*) continue ;; esac
      case "$_re" in ''|*[!0-9]*) continue ;; esac
      if [ "$_rs" -gt "$_re" ]; then _sr="$_rs"; _rs="$_re"; _re="$_sr"; fi
      if [ "$_rs" -le "$g_end" ] && [ "$_re" -ge "$g_start" ]; then _pl_hit=1; fi
    done
    [ "$_pl_hit" = 1 ] || continue
    _nf="$(printf '%s' "$_row" | awk -F'|' '{ print NF }')"
    _cov=""
    if [ "${_nf:-0}" -ge 9 ]; then
      _cov="$(printf '%s' "$_row" | awk -F'|' '{ gsub(/^[ \t]+|[ \t]+$/, "", $6); print $6 }')"
    fi
    _norm="$(printf '%s' "$_cov" | tr -d '*`' | tr '[:lower:]' '[:upper:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$_norm" in
      ''|FULL|N/A)
        if [ "$B24_RESULT" = nooverlap ]; then B24_RESULT=nogap; B24_ROW="$_row"; B24_COV="$_cov"; fi ;;
      *)
        B24_RESULT=gap; B24_ROW="$_row"; B24_COV="$_cov"; return 0 ;;
    esac
  done <<< "$B24_TABLE"
  return 0
}

# codex_effort_scan <stderr-file> <lane> <effort> — B2.5's reading of the driver's dispatch
# announcements (`  <lane>: blind-audit effort=<value> access=…`), printed as `<any>\t<exact>\t<lines>`:
# how many announcement lines the lane has, how many name EXACTLY <effort> (the whole token after
# `effort=`, up to a blank or the end — "effort=highest" is not "high"), and every line of that lane,
# '|'-joined. Lane and effort are compared as LITERAL strings passed through the environment — never
# interpolated into a regex (P2-48, ADV-B56): a caller's ZUVO_BLIND_AUDIT_EFFORT such as "h.gh", or the
# "." in "codex-5.3", must not match other text. A scan that cannot run FAILS: status != 0, nothing on
# stdout, the reason on stderr — never a silent "0 lines", which reads exactly like a real miss.
codex_effort_scan() {
  if [ ! -r "${1:-}" ]; then echo "codex_effort_scan: cannot read '${1:-}'" >&2; return 2; fi
  BAS_LANE="${2:-}" BAS_EFF="${3:-}" LC_ALL=C awk '
    BEGIN { lane = ENVIRON["BAS_LANE"]; eff = ENVIRON["BAS_EFF"] }
    {
      line = $0; sub(/\r$/, "", line); s = line; sub(/^[ \t]+/, "", s)
      if (lane == "" || substr(s, 1, length(lane) + 1) != lane ":") next
      gsub(/\t/, " ", line); lines = lines line "|"
      r = substr(s, length(lane) + 2); sub(/^[ \t]+/, "", r)
      if (r !~ /^blind-audit[ \t]+effort=/) next
      any++
      sub(/^blind-audit[ \t]+effort=/, "", r); sub(/[ \t].*$/, "", r)
      if (r == eff) exact++
    }
    END { printf "%d\t%d\t%s\n", any, exact, lines }' "$1"
}

echo "== smoke-blind-audit: Plan B Task 10 =="

# ═══════════════════════════════════════════════════════════════════════════
# SMOKE-B1 — mock panel end to end, gates unaffected (always runs, fully hermetic)
# ═══════════════════════════════════════════════════════════════════════════
echo "-- SMOKE-B1: mock panel (hermetic) --"

T="$(mktemp -d)" || { record FAIL "precondition: mktemp -d" "mktemp -d failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

SHIM="$T/shim"; mkdir -p "$SHIM"
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SHIM" timeout:gtimeout gtimeout:timeout jq
[ -e "$SHIM/timeout" ] || { record FAIL "precondition: GNU timeout available" "the driver cannot run without it"; exit 1; }
[ -e "$SHIM/jq" ] || { record FAIL "precondition: jq available (shim)" "the driver cannot run without it"; exit 1; }

TMPD="$T/tmp"; WORK="$T/work"; B1HOME="$T/home"
mkdir -p "$TMPD" "$WORK" "$B1HOME"
B1_ZUVO_HOME="$B1HOME/.zuvo"
BASE_PATH="$SHIM:$MOCKS:/usr/bin:/bin"

SRC="$T/src"; mkdir -p "$SRC"
P="$SRC/p.sh"; TT="$SRC/p.test.sh"
printf '#!/bin/sh\np() { echo hi; }\n' > "$P"
printf '#!/bin/sh\ntrue\n' > "$TT"

# drive <tag> [EXTRA_ENV=val ...] -- <driver args...> — F7: every B1 driver call runs under `env -i`
# with an EXPLICIT minimal environment (HOME, ZUVO_HOME, TMPDIR=$T/tmp, PATH, the harness vars) —
# never this process's own environment, so a stray ZUVO_BLIND_AUDIT_PANEL or a real TMPDIR in the
# CALLER's shell can never leak into what is supposed to be a fully mocked, isolated run. Modelled on
# tests/hooks/test-adversarial-blind-audit.sh's own drive().
drive() {
  local tag="$1" rc=0; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  ( cd "$WORK" && env -i HOME="$B1HOME" ZUVO_HOME="$B1_ZUVO_HOME" TMPDIR="$TMPD" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_PROVIDER_BENCH=0 \
      ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
      PATH="$BASE_PATH" "${envs[@]}" bash "$AR" "$@" ) < /dev/null > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
# drive_hook <tag> <stdin-text> — F7/S7: the post-skill hook, the SAME hermetic env as drive() (not
# just HOME/PATH) — ZUVO_HOME and TMPDIR unused by the hook today, but kept identical for the same
# reason drive() has them: nothing about what this call can see should depend on which vars happen
# to matter this week.
drive_hook() {
  local tag="$1" input="$2" rc=0
  printf '%s' "$input" | env -i HOME="$B1HOME" ZUVO_HOME="$B1_ZUVO_HOME" TMPDIR="$TMPD" \
    ZUVO_NO_CAFFEINATE=1 PATH="$BASE_PATH" bash "$HOOK" > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}

# B1.1 — the 3-mock strict run, end to end, incl. the ledger. F9: also proves the log MECHANISM
# itself — the 3 rows NAME the 3 mocks (col 14) and MOCK_CALL_LOG recorded exactly 3 calls — so
# B1.6's "0 calls" later is meaningful evidence, not an untested assertion about an untested log.
rc=0
drive b11 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" \
  MOCK_CALL_LOG="$T/b11.calls" -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b11)"
ok=1; why=""
[ "$rc" -eq 0 ] || { ok=0; why="$why exit=$rc"; }
printf '%s\n' "$out" | sed -n 1p | grep -qx 'Audit mode: strict' || { ok=0; why="$why line1"; }
printf '%s\n' "$out" | grep -qx 'Coverage verdict: REWRITE' || { ok=0; why="$why verdict"; }
printf '%s\n' "$out" | grep -q '^Audit panel: strict valid=3/3' || { ok=0; why="$why panel-line"; }
printf '%s\n' "$out" | grep -q 'mock-strict-fix:' || { ok=0; why="$why fix-row"; }
n_rows="$(awk -F'\t' '$1 != "SUMMARY" && $3 == "blind-audit" { n++ } END { print n + 0 }' "$B1_ZUVO_HOME/adversarial.log" 2>/dev/null)"
[ "$n_rows" = 3 ] || { ok=0; why="$why log-rows=$n_rows"; }
for m in mock-strict-clean mock-strict-fix mock-strict-rewrite; do
  awk -F'\t' -v p="$m" '$1 != "SUMMARY" && $3 == "blind-audit" && $14 == p { found = 1 } END { exit !found }' \
    "$B1_ZUVO_HOME/adversarial.log" 2>/dev/null || { ok=0; why="$why log-missing-$m"; }
done
calls_n="$(wc -l < "$T/b11.calls" 2>/dev/null | tr -d ' ')"; [ -n "$calls_n" ] || calls_n=0
[ "$calls_n" = 3 ] || { ok=0; why="$why calls=$calls_n"; }
if [ "$ok" = 1 ]; then record PASS "B1.1 3-mock strict run (log names the 3 mocks, 3 calls recorded)" "exit=$rc rows=$n_rows calls=$calls_n"
else record FAIL "B1.1 3-mock strict run" "mismatch:$why exit=$rc out_head=$(printf '%s' "$out" | head -3 | tr '\n' '|')"
fi

# B1.2 — the post-skill hook still reminds: HOME=$B1HOME's adversarial.log holds ONLY blind-audit
# rows (from B1.1), which the gate must NOT count as evidence a review ran (Task 2 / X1). Pinned
# EXACTLY, not just a MANDATORY substring: zuvo:build is a code-mode skill (the hook's second
# skill-detection loop), so the injected reminder's ${REVIEW_MODE} substitution must resolve to
# "code" — a regression that always emitted --mode test (or vice versa) would still contain
# "MANDATORY" and pass the old check.
drive_hook b12 'zuvo:build was just run'; hook_rc=$?
hook_out="$(out b12)"
ctx="$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
ok=1; why=""
[ "$hook_rc" -eq 0 ] || { ok=0; why="$why exit=$hook_rc"; }
case "$ctx" in
  "MANDATORY: zuvo:build requires adversarial review but none was detected."*) ;;
  *) ok=0; why="$why message-prefix" ;;
esac
case "$ctx" in
  *"adversarial-review --json --mode code"*) ;;
  *) ok=0; why="$why missing-exact--mode-code" ;;
esac
case "$ctx" in *"--mode test"*) ok=0; why="$why wrongly-carries--mode-test" ;; esac
if [ "$ok" = 1 ]; then
  record PASS "B1.2 post-skill hook still reminds, --mode code exactly (blind-audit rows don't count as review)" "rc=$hook_rc"
else
  record FAIL "B1.2 post-skill hook still reminds, --mode code exactly" "mismatch:$why rc=$hook_rc out=$(printf '%s' "$hook_out" | head -c 200)"
fi

# B1.3 — an echo provider in the panel: valid=2/3, exit 0.
rc=0
drive b13 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-echo-prompt" \
  -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b13)"
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^Audit panel: strict valid=2/3'; then
  record PASS "B1.3 echo provider -> valid=2/3, exit 0" "exit=$rc"
else
  record FAIL "B1.3 echo provider -> valid=2/3, exit 0" "exit=$rc out_head=$(printf '%s' "$out" | sed -n 2p)"
fi

# B1.4 — exactly one valid answer: exit 3 (degraded).
rc=0
drive b14 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-invalid-block mock-fail" \
  -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b14)"
if [ "$rc" -eq 3 ] && printf '%s\n' "$out" | grep -q 'Audit panel: degraded valid=1/3'; then
  record PASS "B1.4 one valid -> exit 3 (degraded)" "exit=$rc"
else
  record FAIL "B1.4 one valid -> exit 3 (degraded)" "exit=$rc out_head=$(printf '%s' "$out" | sed -n 2p)"
fi

# B1.5 — no valid answer: exit 2, stdout EMPTY.
rc=0
drive b15 ZUVO_REVIEW_TEST_PROVIDERS="mock-invalid-block mock-echo-prompt mock-fail" \
  -- --mode blind-audit --production "$P" --test "$TT" || rc=$?
out="$(out b15)"
# Byte-size check on the file, not `[ -z "$out" ]`: `$()` strips trailing newlines, so stdout made of
# only blank lines would wrongly read as "empty" through the trimmed variable (the same pitfall
# test-blind-audit-panel.sh's run() helper already guards against).
if [ "$rc" -eq 2 ] && [ ! -s "$T/b15.out" ]; then
  record PASS "B1.5 no valid answer -> exit 2, empty stdout" "exit=$rc"
else
  record FAIL "B1.5 no valid answer -> exit 2, empty stdout" "exit=$rc out_len=${#out} file_size=$(wc -c < "$T/b15.out" 2>/dev/null | tr -d ' ')"
fi

# B1.6 — a 400001-byte production file: exit 6, and NO provider was ever invoked (a mock call-log
# proves it — not only the exit code; meaningful because B1.1 just proved the same log mechanism
# correctly records 3/3 calls when 3 lanes DO run).
HUGE="$SRC/huge.sh"
head -c 400001 /dev/zero | tr '\0' 'x' > "$HUGE"
huge_sz="$(wc -c < "$HUGE" | tr -d ' ')"
# S6: pre-create the log EMPTY, so "still exists and is empty" is what we check — an ABSENT file
# must never silently read as "0 calls" (the old `wc -l < missing-file 2>/dev/null` produced no
# output, which the fallback then turned into 0, indistinguishable from a real zero-calls run).
: > "$T/b16.calls"
rc=0
drive b16 ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" \
  MOCK_CALL_LOG="$T/b16.calls" -- --mode blind-audit --production "$HUGE" --test "$TT" || rc=$?
calls_log_state="absent"
if [ -f "$T/b16.calls" ]; then
  if [ -s "$T/b16.calls" ]; then calls_log_state="non-empty:$(wc -l < "$T/b16.calls" | tr -d ' ') lines"
  else calls_log_state="present-and-empty"; fi
fi
if [ "$rc" -eq 6 ] && [ "$huge_sz" = 400001 ] && [ "$calls_log_state" = "present-and-empty" ]; then
  record PASS "B1.6 400001-byte input -> exit 6, no provider invoked" "exit=$rc size=$huge_sz calls_log=$calls_log_state"
else
  record FAIL "B1.6 400001-byte input -> exit 6, no provider invoked" "exit=$rc size=$huge_sz calls_log=$calls_log_state"
fi

# B1.7 — P2-42: the live branch's adversarial.log bookkeeping never rewrites a pre-existing log. A temp
# ZUVO_HOME's log is seeded with sentinel rows and taken through the SAME calls SMOKE-B2 makes around
# its dispatch (live_adv_log_path, adv_log_rows before, adv_log_growth after): (a) rows appended during
# the "dispatch" — this run's and a concurrent writer's — all survive; (b) a pre-count that FAILED (the
# log unreadable at that moment) is reported as no count, never as 0, and every row stays in place — the
# old line-count trim read it as 0, and `head -n 0` (GNU) then emptied the whole log. Byte-identical, by
# cmp. Plus the static half: no code line of this script redirects to, moves, copies over or edits the
# live log variable in place.
ok=1; why=""
b17_home="$T/b17home/.zuvo"; mkdir -p "$b17_home"
b17_log="$(ZUVO_HOME="$b17_home" live_adv_log_path)"
[ "$b17_log" = "$b17_home/adversarial.log" ] || { ok=0; why="$why path=[$b17_log]"; }
printf 'SENTINEL-1\tpre-existing row\nSENTINEL-2\tpre-existing row\n' > "$b17_log"
b17_pre="$(adv_log_rows "$b17_log")" || b17_pre=""
[ "$b17_pre" = 2 ] || { ok=0; why="$why pre=[$b17_pre]"; }
printf 'RUN-ROW\tblind-audit\nCONCURRENT-ROW\tcode\n' >> "$b17_log"
cp "$b17_log" "$T/b17.expect"
b17_msg_a="$(adv_log_growth "$b17_log" "$b17_pre")"
cmp -s "$b17_log" "$T/b17.expect" || { ok=0; why="$why (a)rows-lost:$(tr '\n' '|' < "$b17_log")"; }
case "$b17_msg_a" in *": 2 row(s) appended"*) ;; *) ok=0; why="$why (a)msg=[$b17_msg_a]" ;; esac
chmod 000 "$b17_log"
b17_pre="$(adv_log_rows "$b17_log")" || b17_pre=""
chmod 600 "$b17_log"
if [ -r "$b17_log" ] && [ "$(id -u)" != 0 ]; then
  [ -z "$b17_pre" ] || { ok=0; why="$why (b)unreadable-log-counted-as=[$b17_pre]"; }
fi
printf 'RUN-ROW-2\tblind-audit\n' >> "$b17_log"
cp "$b17_log" "$T/b17.expect"
b17_msg_b="$(adv_log_growth "$b17_log" "$b17_pre")"
cmp -s "$b17_log" "$T/b17.expect" || { ok=0; why="$why (b)rows-lost:$(tr '\n' '|' < "$b17_log")"; }
b17_src="$(sed -E 's/(^|[[:space:]])#.*$//' "${BASH_SOURCE[0]:-$0}")"
b17_writes="$(printf '%s\n' "$b17_src" | awk '
    /\$\{?_adv_log/ && (/>/ || /(^|[^[:alnum:]_])(mv|cp|tee|truncate|dd)[[:space:]]/ || /sed[[:space:]]+-i/) { print NR ": " $0 }
  ')"
[ -z "$b17_writes" ] || { ok=0; why="$why writes-live-log:[$(printf '%s' "$b17_writes" | tr '\n' '|')]"; }
# (c) P3-17: a last row cut mid-append (no newline) is a row — `wc -l` counted 2 here. (d) P3-27: a log
# that SHRANK (another process truncated it) reads as such, never as "-2 row(s) appended".
printf 'ROW-1\nROW-2\nROW-3-cut-mid-append' > "$T/b17-partial.log"
b17_partial="$(adv_log_rows "$T/b17-partial.log")" || b17_partial=""
[ "$b17_partial" = 3 ] || { ok=0; why="$why (c)unterminated-last-row-counted-as=[$b17_partial]"; }
b17_msg_d="$(adv_log_growth "$T/b17-partial.log" 5)"
case "$b17_msg_d" in *": log shrank by 2 row(s)"*) ;; *) ok=0; why="$why (d)msg=[$b17_msg_d]" ;; esac
if [ "$ok" = 1 ]; then
  record PASS "B1.7 live-log bookkeeping is read-only (sentinel + mid-run rows survive byte-identical, even after a failed pre-count); an unterminated last row counts, a shrink reads as one" \
    "(a) ${b17_msg_a#"$b17_log": } (b) ${b17_msg_b#"$b17_log": } (c) rows=$b17_partial (d) ${b17_msg_d#"$T/b17-partial.log": }"
else
  record FAIL "B1.7 live-log bookkeeping is read-only" "mismatch:$why"
fi

# B1.8 — P2-63 + F1/S8/S5/ADV-B66: which live panels are an EXCUSED infra outage (exit 75). Fixed
# outcome strings through the SAME live_outcomes_excused SMOKE-B2 calls; each case names its reason.
ok=1; why=""
# b18 <want: yes|no> <outcomes> <valid> <rc> <label>
b18() {
  local got=no
  if live_outcomes_excused "$2" "$3" "$4"; then got=yes; fi
  [ "$got" = "$1" ] || { ok=0; why="$why $5(want=$1,got=$got)"; }
}
b18 yes "agy:timeout,codex-5.3:quota" 0 124 timeout+quota
b18 yes " agy : auth ,codex-5.3:timeout"$'\r' 0 2 cr-and-blanks
b18 yes "agy:ok,codex-5.3:timeout" 1 3 one-valid-one-timeout
b18 no  "agy:empty,codex-5.3:timeout" 0 2 empty-is-not-infra
b18 no  "agy:empty" 1 3 empty-alone
b18 no  "agy:invalid,codex-5.3:timeout" 0 2 invalid-is-not-infra
b18 no  "agy:no-runner,codex-5.3:timeout" 0 1 no-runner
b18 no  "agy:unverified,codex-5.3:timeout" 0 2 unverified
b18 no  "agy:unavailable,codex-5.3:timeout" 0 2 unknown-outcome-unavailable
b18 no  "agy:ok" 1 3 all-ok-valid-1
b18 no  "agy:timeout,codex-5.3:ok" 1 0 rc-0-contract
b18 no  "agy:timeout,codex-5.3:timeout" 2 2 valid-2
b18 no  "" 0 2 no-outcomes
if [ "$ok" = 1 ]; then
  record PASS "B1.8 excused outage = rc!=0, <2 valid, >=1 non-ok, every non-ok timeout/auth/quota (empty/invalid/unknown never)" "13 cases"
else
  record FAIL "B1.8 excused-outage classification" "mismatch:$why"
fi

# B1.9 — P2-60 + P2-46: B2.4's scan of the merged table for the guard range (here 11-14, sum.sh's).
ok=1; why=""
b19_hdr='| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |'
b19_sep='|----|------|------------------|--------------------|----------|---------------|-------|'
# b19 <want: gap|nogap|nooverlap> <label> <row>... — one merged block holding exactly those rows.
b19() {
  local want="$1" label="$2" blk; shift 2
  blk="$(printf 'Audit mode: strict\nAudit panel: strict valid=2/2 providers=agy,codex-5.3\n\n%s\n%s\n' "$b19_hdr" "$b19_sep"; printf '%s\n' "$@")"
  b24_scan "$blk" 11 14
  [ "$B24_RESULT" = "$want" ] || { ok=0; why="$why $label(want=$want,got=$B24_RESULT,row=[$B24_ROW])"; }
}
b19 gap a-later-gap-row-is-not-hidden-by-a-full-one \
  '| agy:B1 | branch | 11-14 | owned | FULL | sum.test.sh:3 | claims covered [agy] |' \
  '| codex-5.3:B1 | branch | 11-13 | owned | NONE | none | empty input never passed [codex-5.3] |'
b19 gap pipe-in-evidence-and-notes-keeps-coverage \
  '| agy:B2 | branch | 12 | owned | PARTIAL | sum.test.sh:3 | x | y | a|b notes [agy] |'
b19 gap sub-range-with-spaced-dash '| agy:B3 | branch | 2-3, 13 - 20 | owned | NONE | none | n [agy] |'
b19 nogap short-row-has-no-coverage-cell '| agy:B4 | branch | 11-14 |'
b19 nogap bold-lowercase-full-is-full '| agy:B5 | branch | 11-14 | owned | **full** | t:1 | n [agy] |'
b19 nogap na-is-not-a-gap '| agy:B6 | branch | 11-14 | owned | N/A | t:1 | n [agy] |'
b19 nooverlap outer-span-is-not-an-overlap '| agy:B7 | branch | 3-4, 20-22 | owned | NONE | none | n [agy] |'
b19 gap reversed-sub-range-still-overlaps '| agy:B8 | branch | 13-5 | owned | NONE | none | n [agy] |'
b19 gap annotated-full-is-not-full-like-bap-merge '| agy:B9 | branch | 11-14 | owned | FULL (manual) | t:1 | n [agy] |'
if [ "$ok" = 1 ]; then
  record PASS "B1.9 B2.4 scan: every overlapping row checked, 7-cell rows only, FULL/N/A normalised, reversed ranges ordered" "9 cases"
else
  record FAIL "B1.9 B2.4 scan" "mismatch:$why"
fi

# B1.10 — P2-48: B2.5's effort scan compares the lane and the effort LITERALLY.
ok=1; why=""
b110_err="$T/b110.err"
printf '%s\n' '  Running: codex-5.3...' '  codex-5.3: blind-audit effort=high access=none' \
  '  codex-5x3: blind-audit effort=high access=none' '  codex-5.4: blind-audit effort=highest access=none' > "$b110_err"
# b110 <lane> <effort> <want any> <want exact> <label>
b110() {
  local _a _e _l
  IFS=$'\t' read -r _a _e _l <<< "$(codex_effort_scan "$b110_err" "$1" "$2")"
  [ "${_a:-}" = "$3" ] && [ "${_e:-}" = "$4" ] || { ok=0; why="$why $5(any=${_a:-}/$3,exact=${_e:-}/$4)"; }
}
b110 codex-5.3 high 1 1 exact-token
b110 codex-5.3 'h.gh' 1 0 regex-metachar-effort-is-literal
b110 codex-5.3 'hig' 1 0 prefix-is-not-the-token
b110 codex-5.4 high 1 0 highest-is-not-high
b110 codex-5.5 high 0 0 no-line-for-the-lane
# P3-24: a scan that cannot run (here, no stderr file) fails LOUDLY — status != 0, nothing on stdout,
# the reason on stderr — never "0 lines", which B2.5 would read as the lane's missing announcement.
b110_st=0; b110_out="$(codex_effort_scan "$T/b110-missing.err" codex-5.3 high 2> "$T/b110-miss.stderr")" || b110_st=$?
[ "$b110_st" -ne 0 ] && [ -z "$b110_out" ] && [ -s "$T/b110-miss.stderr" ] \
  || { ok=0; why="$why scan-failure-masked(st=$b110_st,out=[$b110_out],stderr=[$(cat "$T/b110-miss.stderr" 2>/dev/null)])"; }
if [ "$ok" = 1 ]; then
  record PASS "B1.10 B2.5 effort scan: literal lane + whole effort token; a scan that cannot run fails loudly" "6 cases"
else
  record FAIL "B1.10 B2.5 effort scan" "mismatch:$why"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SMOKE-B2 — live panel, real model CLIs (only with ZUVO_LIVE_SMOKE=1)
# ═══════════════════════════════════════════════════════════════════════════
# B1 never touched this process's own HOME/PATH/TMPDIR (every call was `env -i` inside drive()), so
# there is nothing to restore here — $HOME is still the real one throughout.

live_ran=0
live_excused=0

echo "-- SMOKE-B2: live panel --"
if [ "${ZUVO_LIVE_SMOKE:-}" != "1" ]; then
  echo "SKIP live"
else
  live_ran=1

  # F8/S1: unset FIRST, before the host-detection probe below AND the live dispatch — a leaked
  # ZUVO_ADVERSARIAL_TEST_HARNESS from the caller must not turn the "Host detected:" probe into a
  # report about a mocked panel either.
  unset ZUVO_REVIEW_TEST_PROVIDERS ZUVO_ADVERSARIAL_TEST_HARNESS ZUVO_BLIND_AUDIT_PANEL \
    ZUVO_BLIND_AUDIT_ALLOWLIST ZUVO_REVIEW_PROVIDER ZUVO_REVIEW_PROVIDER_PICK

  # S1: host detection from the driver's OWN stderr — no awk-extracted/eval'd detect_host_platform(),
  # no copied lane->vendor case. `--list-providers --mode blind-audit` dispatches nothing (Task 4's
  # A4 case) and its stderr carries "Host detected: <h> -- ..." (verified live: that line is printed
  # by the shared host-exclusion prologue at scripts/adversarial-review.sh:~1618, which runs before
  # ANY mode branch — confirmed present for --list-providers --mode blind-audit specifically, not
  # assumed). candidates (stdout) is kept for B2.3's restored candidate-list cross-check.
  list_out="$(bash "$AR" --list-providers --mode blind-audit 2>"$T/b2-list.err")"; list_rc=$?
  candidates="$(printf '%s' "$list_out" | tr '\n' ' ')"
  host_line="$(grep -m1 -E '^[[:space:]]*Host detected:' "$T/b2-list.err" 2>/dev/null)"
  h="$(printf '%s' "$host_line" | sed -n 's/^[[:space:]]*Host detected:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*--.*/\1/p')"

  # b20_ok gates the costly live dispatch below (ADV-B38): a FAIL on B2.0a or B2.0c means host
  # detection itself is broken, so B2.1-B2.5 cannot mean anything either — skip the real API call
  # and the cascading confusing failures instead of spending it anyway.
  b20_ok=1
  if [ "$list_rc" -eq 0 ] && [ -n "$h" ]; then
    record PASS "B2.0a host detected on the driver's own stderr" "host=[$h] line=[$host_line]"
  else
    record FAIL "B2.0a host detected on the driver's own stderr" \
      "list_rc=$list_rc host_line=[$host_line] stderr=$(cat "$T/b2-list.err" 2>/dev/null | tr '\n' '|')"
    b20_ok=0
  fi

  # Independent oracle: this run is INSIDE Claude Code (CLAUDECODE is how the harness we are running
  # under marks that), so the detected host MUST be exactly "claude" — never trust the detector to
  # grade its own homework.
  if [ -n "${CLAUDECODE:-}" ]; then
    if [ "$h" = claude ]; then
      record PASS "B2.0b independent oracle: CLAUDECODE set -> detected host is claude" "h=[$h]"
    else
      record FAIL "B2.0b independent oracle: CLAUDECODE set -> detected host is claude" "h=[$h] CLAUDECODE=${CLAUDECODE}"
    fi
  fi

  excluded_lanes="$(bap_vendor_excluded "$h" 2>/dev/null)"
  if [ -z "$h" ] || [ -z "$excluded_lanes" ]; then
    record FAIL "B2.0c host vendor exclusion set is non-empty" \
      "h=[$h] excluded_lanes=[$excluded_lanes] — detection failing, or an empty excluded set, is always a FAIL"
    b20_ok=0
  else
    record PASS "B2.0c host vendor exclusion set is non-empty" "h=[$h] excluded_lanes=[$excluded_lanes]"
  fi

  expected_pins=""
  for _pin in agy codex-5.3; do
    case " $excluded_lanes " in *" $_pin "*) ;; *) expected_pins="$expected_pins $_pin" ;; esac
  done
  expected_pins="${expected_pins# }"
  echo "  note: h=[$h] excluded_lanes=[$excluded_lanes] expected_pins=[$expected_pins] candidates=[$candidates]"

  # S4: the expected effort is DERIVED from the same env this live dispatch will see (unset -> high)
  # — never a hardcoded "high" — read BEFORE the dispatch so it reflects exactly what the caller had;
  # neither ZUVO_BLIND_AUDIT_EFFORT nor ZUVO_CODEX_EFFORT_AUDIT is in the unset list above.
  LIVE_BLIND_AUDIT_EFFORT="${ZUVO_BLIND_AUDIT_EFFORT:-${ZUVO_CODEX_EFFORT_AUDIT:-high}}"

if [ "$b20_ok" != 1 ]; then
  # ADV-B38: B2.0a/B2.0c already FAILED above (host detection is broken) — B2.1-B2.5 would only
  # cascade confusing failures from a panel that can't mean anything, and the dispatch below is a
  # REAL, costly model-CLI call. Skip it instead of spending it on a run whose precondition is dead.
  note "B2.1-B2.5 live dispatch" "SKIPPED — B2.0a/B2.0c precondition failed above (host=[$h] excluded_lanes=[$excluded_lanes]); not wasting a real API call"
else
  # ADV-B39/P2-42: SMOKE-B2 dispatches through the REAL environment (unlike SMOKE-B1's env -i mocks),
  # so the panel appends real blind-audit rows to the developer's own, SHARED adversarial.log. They
  # stay there: no review-coverage gate counts a blind-audit row, and a trim cannot tell this run's rows
  # from a concurrent run's (it used to cut the log back to a pre-run line count — deleting other
  # writers' rows, and the whole log when that count failed). Only a READ-ONLY row count is kept, for
  # one diagnostic NOTE after the dispatch (adv_log_growth; pinned by B1.7).
  _adv_log="$(live_adv_log_path)"
  _adv_log_pre="$(adv_log_rows "$_adv_log")" || _adv_log_pre=""

  rc=0
  json_out="$(ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_PIN_PROVIDERS="agy codex-5.3" \
    bash "$AR" --mode blind-audit --production "$FXLIVE/sum.sh" --test "$FXLIVE/sum.test.sh" --json \
    2>"$T/b2.err")" || rc=$?

  status="$(printf '%s' "$json_out" | jq -r '.status' 2>/dev/null)"; : "${status:=}"
  valid_n="$(printf '%s' "$json_out" | jq -r '.valid_providers | length' 2>/dev/null)"; : "${valid_n:=0}"
  case "$valid_n" in ''|*[!0-9]*) valid_n=0 ;; esac
  outcomes="$(printf '%s' "$json_out" | jq -r '.provider_outcomes' 2>/dev/null)"; : "${outcomes:=}"
  merged="$(printf '%s' "$json_out" | jq -r '.merged_block // empty' 2>/dev/null)"

  if [ "$rc" -eq 0 ] && [ "$status" = strict ] && [ "$valid_n" -ge 2 ]; then
    record PASS "B2.1 exit 0, Audit panel: strict valid>=2" "exit=$rc status=$status valid=$valid_n"

    panel_line="$(printf '%s\n' "$merged" | sed -n 2p)"
    providers_field="$(printf '%s' "$panel_line" | sed -n 's/.*providers=\([^ ]*\).*/\1/p')"
    failed_field="$(printf '%s' "$panel_line" | sed -n 's/.* failed=\([^ ]*\)$/\1/p')"
    valid_names="$(printf '%s' "$providers_field" | tr ',' ' ')"
    failed_names="$(printf '%s' "$failed_field" | tr ',' '\n' | cut -d: -f1 | tr '\n' ' ')"
    all_names=" $valid_names $failed_names "

    # S2: every expected pin among the providers (dispatched, valid or not). A required pin missing
    # from the panel is a FAIL. Empty expected_pins is a NOTE ONLY when excluded_lanes legitimately
    # contains BOTH would-be pins — anything else (a computation bug that emptied expected_pins
    # without the vendor exclusion actually explaining it) is a FAIL, not a free pass.
    if [ -z "$expected_pins" ]; then
      case " $excluded_lanes " in *" agy "*) _agy_excl=1 ;; *) _agy_excl=0 ;; esac
      case " $excluded_lanes " in *" codex-5.3 "*) _cx_excl=1 ;; *) _cx_excl=0 ;; esac
      if [ "$_agy_excl" = 1 ] && [ "$_cx_excl" = 1 ]; then
        note "B2.2 expected pins present" "N/A — both legitimately excluded by host=$h (excluded=[$excluded_lanes])"
      else
        record FAIL "B2.2 expected pins present" \
          "expected_pins computed empty but excluded_lanes=[$excluded_lanes] (host=$h) does not legitimately explain it"
      fi
    else
      pin_ok=1; pin_missing=""
      for _pin in $expected_pins; do
        case "$all_names" in *" $_pin "*) ;; *) pin_ok=0; pin_missing="$pin_missing $_pin" ;; esac
      done
      if [ "$pin_ok" = 1 ]; then
        record PASS "B2.2 expected pins present" "expected=[$expected_pins] providers=[$all_names]"
      else
        record FAIL "B2.2 expected pins present" "missing=[$pin_missing] providers=[$all_names]"
      fi
    fi

    # S1: no host-vendor lane among EITHER the candidate list OR the dispatched providers — the SAME
    # excluded-lane set B2.0c computed (never a hardcoded "claude"), correct on a Codex/Antigravity/
    # Cursor/Kimi/Qwen host too. The candidate-list half is the restored cross-check: a lane that
    # never even CANDIDATES is a stronger guarantee than one that merely was not picked this run.
    host_lane_leak_candidates=""
    for _l in $excluded_lanes; do
      case " $candidates " in *" $_l "*) host_lane_leak_candidates="$host_lane_leak_candidates $_l" ;; esac
    done
    host_lane_leak_dispatched=""
    for _l in $excluded_lanes; do
      case "$all_names" in *" $_l "*) host_lane_leak_dispatched="$host_lane_leak_dispatched $_l" ;; esac
    done
    if [ -z "$host_lane_leak_candidates" ] && [ -z "$host_lane_leak_dispatched" ]; then
      record PASS "B2.3 no host-vendor lane among candidates or dispatched providers" \
        "excluded=[$excluded_lanes] candidates=[$candidates] providers=[$all_names]"
    else
      record FAIL "B2.3 no host-vendor lane among candidates or dispatched providers" \
        "leaked_candidates=[$host_lane_leak_candidates] leaked_dispatched=[$host_lane_leak_dispatched] excluded=[$excluded_lanes]"
    fi

    # S3: the fixture's OWN gap — the empty-input guard's line range in sum.sh, found by a
    # NESTING-AWARE, whitespace-tolerant awk: the start pattern tolerates flexible spacing around
    # `-z`/quotes/brackets, and a depth counter (any OTHER "if ... " line inside increments it) finds
    # the guard's OWN matching `fi`, not merely the next `fi` in the file (which a differently-shaped
    # fixture, or a guard containing a nested if, would get wrong).
    guard_range="$(awk '
        start == 0 && $0 ~ /^[[:space:]]*if[[:space:]]+\[[[:space:]]*-z[[:space:]]+"\$1"[[:space:]]*\]/ {
          start = NR; depth = 1; next
        }
        start > 0 {
          if (NR != start && $0 ~ /^[[:space:]]*if[[:space:]]/) depth++
          if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
            depth--
            if (depth == 0) { print start "-" NR; exit }
          }
        }
      ' "$FXLIVE/sum.sh")"
    g_start="${guard_range%%-*}"; g_end="${guard_range##*-}"
    if [ -z "$g_start" ] || [ -z "$g_end" ]; then
      record FAIL "B2.4 sum.sh's untested branch appears as a non-FULL row" \
        "could not locate the empty-input guard's line range in $FXLIVE/sum.sh by content"
    else
      # ADV-B46/P2-46/P2-60: overlap alone is not enough — the row's OWN coverage cell must be a gap,
      # and EVERY overlapping row is checked (b24_scan; pinned by B1.9).
      b24_scan "$merged" "$g_start" "$g_end"
      case "$B24_RESULT" in
        gap)
          record PASS "B2.4 sum.sh's untested branch (lines $guard_range) appears as a non-FULL row" \
            "coverage=$B24_COV row=$B24_ROW" ;;
        nogap)
          record FAIL "B2.4 sum.sh's untested branch (lines $guard_range) appears as a non-FULL row" \
            "rows overlap $guard_range but none has a non-FULL coverage cell (FULL, N/A, empty, or a row short of 7 cells); first=[$B24_ROW] table=$(printf '%s' "$B24_TABLE" | tr '\n' '|')" ;;
        *)
          record FAIL "B2.4 sum.sh's untested branch (lines $guard_range) appears as a non-FULL row" \
            "no sub-range of any row's production-lines overlaps $guard_range; table=$(printf '%s' "$B24_TABLE" | tr '\n' '|')" ;;
      esac
    fi

    # S4: codex effort — read from the DRIVER's own stderr (the dispatch-loop announcement, D1's
    # single-source blind_audit_codex_effort()), never a raced poller against a temp dir a lane's own
    # runner subshell deletes moments after it finishes. EVERY announcement line for EVERY codex lane
    # in the panel is checked (never `head -1`), against an EXACT anchored token
    # (`effort=<value>` followed by whitespace or end of line), so "effort=highest" cannot pass as
    # "effort=high". <value> is LIVE_BLIND_AUDIT_EFFORT, derived from this run's own env, never
    # hardcoded. No codex lane in this panel -> NOTE, not counted (F4).
    # ADV-B52: derive candidate codex lanes via a `codex-*` pattern match against the panel's own
    # dispatched providers, not a hardcoded pair — a future new codex lane (e.g. codex-5.5) is picked
    # up automatically instead of silently producing an N/A NOTE and quietly losing coverage.
    codex_lanes_in_panel=""
    for _cl in $all_names; do
      case "$_cl" in
        codex-*)
          case " $codex_lanes_in_panel " in
            *" $_cl "*) ;;
            *) codex_lanes_in_panel="$codex_lanes_in_panel $_cl" ;;
          esac
          ;;
      esac
    done
    codex_lanes_in_panel="${codex_lanes_in_panel# }"
    if [ -z "$codex_lanes_in_panel" ]; then
      note "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT" "N/A — no codex lane in this panel (providers=[$all_names])"
    else
      missing=""; evidence=""
      for _cl in $codex_lanes_in_panel; do
        # ADV-B56/P2-48: the lane name AND the caller-controlled effort are compared as literal
        # strings (codex_effort_scan; pinned by B1.10), never interpolated into a regex.
        _any=0; _exact=0; _lane_lines=""
        if ! _scan="$(codex_effort_scan "$T/b2.err" "$_cl" "$LIVE_BLIND_AUDIT_EFFORT")"; then
          missing="$missing ${_cl}(scan-failed)"; continue
        fi
        IFS=$'\t' read -r _any _exact _lane_lines <<< "$_scan"
        case "$_any" in ''|*[!0-9]*) _any=0 ;; esac
        case "$_exact" in ''|*[!0-9]*) _exact=0 ;; esac
        if [ "$_any" -eq 0 ]; then
          missing="$missing ${_cl}(no-line)"
        elif [ "$_exact" != "$_any" ]; then
          missing="$missing ${_cl}(wrong-effort:$_lane_lines)"
        else
          evidence="${evidence}${evidence:+; }$_lane_lines"
        fi
      done
      if [ -z "$missing" ]; then
        record PASS "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT (driver stderr, every announcement line)" "$evidence"
      else
        record FAIL "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT (driver stderr, every announcement line)" \
          "missing/wrong: [$missing] stderr_tail=$(tail -20 "$T/b2.err" | tr '\n' '|')"
      fi
    fi
  else
    # F1/S8/S5/ADV-B66/P2-63: EXCUSED (exit 75) only for an infra outage — live_outcomes_excused
    # (pinned by B1.8): driver exit != 0, < 2 valid, >= 1 non-ok outcome, and every non-ok outcome
    # timeout/auth/quota. `invalid`, `empty` and any other outcome are never excused: none can be told
    # apart from a code or content regression from what `--json` reports.
    if live_outcomes_excused "$outcomes" "$valid_n" "$rc"; then
      live_excused=1
      record PASS "B2.1 live panel infra outage (excused: < 2 valid, driver exit != 0, >=1 failure, every failure timeout/auth/quota)" \
        "exit=$rc status=$status valid=$valid_n outcomes=$outcomes"
      # ADV-B70: symmetry with B2.5's N/A note in the success branch — the excused/infra branch never
      # dispatched cleanly enough to check codex effort announcements, so say so explicitly instead of
      # silently omitting the check (F4 no-inflate: an explicit NOTE, not a phantom PASS).
      note "B2.5 codex effort $LIVE_BLIND_AUDIT_EFFORT" "N/A — run was excused (infra outage), no codex effort check performed"
    else
      record FAIL "B2.1 exit 0, Audit panel: strict valid>=2 (and not an excused outage)" \
        "exit=$rc status=$status valid=$valid_n outcomes=$outcomes"
    fi
  fi

  # P2-42: the live log is only READ here — one diagnostic NOTE of how far it grew (never counted as a
  # check, never a trim; see the pre-count above).
  note "B2 adversarial.log growth" "$(adv_log_growth "$_adv_log" "$_adv_log_pre")"
fi
fi

echo "=== SMOKE RESULT ==="
if [ "$live_ran" = 1 ]; then live_word=ran; else live_word=SKIP; fi
echo "RESULT: executed=$EXECUTED failed=$FAILED live=$live_word"
if [ "$live_excused" = 1 ] && [ "$FAILED" -eq 0 ]; then
  exit 75
elif [ "$FAILED" -eq 0 ] && [ "$EXECUTED" -gt 0 ]; then
  exit 0
else
  exit 1
fi
