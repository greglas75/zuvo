#!/usr/bin/env bash
# test-retro-route-key.sh — the retro telemetry reader's cutover split reads a record's `at` to the
# second, with or without a fractional second.
#
# Test level: SMALL — the shipped `zuvo:retro-telemetry` fence of skills/retro/SKILL.md is cut out and
# run as it ships (bash + python3) over a planted task-telemetry.jsonl in a temp dir. No network, no git.
#
# What it pins: the reader tallies `reviewer-route` under `legacy:<value>` for a record written before
# the cross-vendor router's cutover, under the bare value after it, and under `undated:<value>` only
# when `at` is not a timestamp at all. A writer that keeps sub-second precision (`…T15:23:39.250Z`)
# used to fall into `undated:` — a dated record counted as undated — and, once accepted, must be
# compared by its whole seconds: with the fraction left in, `.` sorts before `Z`, so a record half a
# second AFTER the cutover would read as legacy.
#
# TR_SKILL points the test at another copy of the skill (a RED run against an older revision).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="${TR_SKILL:-$ROOT/skills/retro/SKILL.md}"
fail=0; npass=0
pass() { npass=$((npass + 1)); printf 'PASS: %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 is not installed — the retro telemetry reader did not run"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/retro-route-key.XXXXXX")" || { echo "FAIL: mktemp -d"; exit 1; }
trap 'case "$T" in */retro-route-key.*) rm -rf "$T" ;; esac' EXIT

# The fence, by its own markers: everything from `# >>> zuvo:retro-telemetry` to `# <<< zuvo:retro-telemetry`.
awk '$0 == "# >>> zuvo:retro-telemetry" { on = 1 } on { print } $0 == "# <<< zuvo:retro-telemetry" { done = 1; exit } END { exit !done }' \
  "$SKILL" > "$T/reader.sh" || { bad "the zuvo:retro-telemetry fence is present and closed in $SKILL"; echo "  ---- $npass passed, $fail failed"; exit 1; }
pass "the zuvo:retro-telemetry fence is present and closed"

cutover="$(awk 'match($0, /^ROUTE_CUTOVER = "[^"]+"/) { s = substr($0, RSTART, RLENGTH); sub(/^ROUTE_CUTOVER = "/, "", s); sub(/"$/, "", s); print s; exit }' "$T/reader.sh")"
# Digits only, whole seconds, Zulu: a fraction or a numeric offset is refused here, before any arithmetic.
case "$cutover" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) pass "ROUTE_CUTOVER is a whole-second UTC instant ($cutover)" ;;
  *) bad "ROUTE_CUTOVER is a whole-second UTC instant (got [$cutover])"; echo "  ---- $npass passed, $fail failed"; exit 1 ;;
esac

# rec <at-json-value> <route> — one telemetry record; every other field is a passing value.
rec() { printf '{"at":%s,"reviewer-route":"%s","spec-review":"PASS","quality-review":"PASS q","adversarial":"PASS a","implementer-status":"DONE","failure-strategy":"halt"}\n' "$1" "$2"; }
# run_reader <file> — the `reviewer-route …` line of the reader's output for that telemetry file. The
# reader's exit status ($T/reader.rc) and its stderr ($T/reader.err) are kept, so a crash reads as one in
# the FAIL message, not as an empty `got []`.
# A telemetry file that cannot be planted ends it before the reader runs (reader.rc = "not planted"): the
# previous case's file would otherwise still be there, and its answer could match.
run_reader() {
  local rc=0
  rm -f "$T/out/context/task-telemetry.jsonl" "$T/reader.out" "$T/reader.err"
  if ! { mkdir -p "$T/out/context" && cp "$1" "$T/out/context/task-telemetry.jsonl"; }; then
    echo "not planted" > "$T/reader.rc"; return 0
  fi
  ZUVO_OUTPUT_DIR="$T/out" bash "$T/reader.sh" > "$T/reader.out" 2> "$T/reader.err" || rc=$?
  echo "$rc" > "$T/reader.rc"
  awk 'index($0, "reviewer-route ") == 1' "$T/reader.out"
}
# expect <label> <want-line> <records...> — the reader's reviewer-route line for those records.
expect() {
  local label="$1" want="$2" got
  shift 2
  printf '%s\n' "$@" > "$T/in.jsonl"
  got="$(run_reader "$T/in.jsonl")"
  if [ "$got" = "$want" ]; then pass "$label"
  else bad "$label (got [$got], want [$want]; reader exit $(cat "$T/reader.rc" 2>/dev/null), stderr [$(tr '\n' '|' < "$T/reader.err" 2>/dev/null)])"; fi
}

base="${cutover%Z}"                 # YYYY-MM-DDTHH:MM:SS of the cutover
day="${cutover%%T*}"
before="${day}T00:00:00"            # the same day, midnight: before any cutover later than 00:00:00
sec="${base##*:}"; head="${base%:*}"
next="$head:$(printf '%02d' $((10#$sec + 1)))"   # one second after (the fixture below needs sec < 59)
[ "$((10#$sec))" -lt 59 ] || { bad "fixture: the cutover's seconds field is 59 — pick another way to build 'one second after'"; echo "  ---- $npass passed, $fail failed"; exit 1; }

expect "whole seconds, before the cutover: legacy" \
  "reviewer-route legacy:review-alt=1" "$(rec "\"${before}Z\"" review-alt)"
expect "whole seconds, at the cutover instant: the new vocabulary" \
  "reviewer-route cross-vendor=1" "$(rec "\"${cutover}\"" cross-vendor)"
expect "a FRACTIONAL second after the cutover is dated, and is the new vocabulary — not undated (ADV-114)" \
  "reviewer-route cross-vendor=1" "$(rec "\"${next}.250Z\"" cross-vendor)"
expect "a fractional second INSIDE the cutover's own second is not before it ('.' sorts before 'Z')" \
  "reviewer-route cross-vendor=1" "$(rec "\"${base}.500Z\"" cross-vendor)"
expect "a fractional second before the cutover is legacy" \
  "reviewer-route legacy:review-primary=1" "$(rec "\"${before}.999999Z\"" review-primary)"
expect "not a timestamp (no Z, a bare date, a number, a fraction with no digits) stays undated" \
  "reviewer-route undated:review-alt=4" \
  "$(rec "\"${next}\"" review-alt)" "$(rec "\"${day}\"" review-alt)" "$(rec 17 review-alt)" "$(rec "\"${next}.Z\"" review-alt)"

# The harness itself: a telemetry file that cannot be planted never lets the reader answer from the
# previous case's file (which is still in place at this point).
got="$(run_reader "$T/no-such-telemetry.jsonl")"
if [ -z "$got" ] && [ "$(cat "$T/reader.rc" 2>/dev/null)" = "not planted" ]; then pass "an unplantable telemetry file stops the case before the reader runs"
else bad "an unplantable telemetry file still ran the reader (got [$got], reader.rc [$(cat "$T/reader.rc" 2>/dev/null)])"; fi

echo "  ---- $npass passed, $fail failed"
[ "$fail" -eq 0 ]
