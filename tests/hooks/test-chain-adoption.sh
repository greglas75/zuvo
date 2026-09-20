#!/usr/bin/env bash
# Contract for chain-adoption.py — the tool that answers "did the chained follow-up actually run?"
#
# It exists because that question was answered twice by hand with ad-hoc awk, and the first attempt
# read the wrong column. A tool that produces a number someone acts on has to be pinned to a
# fixture, or it becomes another way to be confidently wrong.
#
# Every case below uses a synthetic runs.log via $ZUVO_HOME, never the real one.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/scripts/zuvo-home/chain-adoption.py"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$TOOL" ] || { bad "scripts/zuvo-home/chain-adoption.py missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export ZUVO_HOME="$TMP"
LOG="$TMP/runs.log"

row() { printf '%s\t%s\t%s\t-\t-\tPASS\t-\t-\tnote\tmain\tabc1234\t-\tTIER1\n' "$1" "$2" "$3" >> "$LOG"; }

# projA: review then mutation-test 10 minutes later      -> PAIRED
# projB: review, no follow-up at all                     -> UNPAIRED
# projC: mutation-test with no review before it          -> STANDALONE
# projD: review, then mutation-test 3 HOURS later        -> UNPAIRED (outside the window)
# projE: mutation-test BEFORE its review                 -> STANDALONE (order matters)
: > "$LOG"
row 2026-09-19T10:00:00Z review        projA
row 2026-09-19T10:10:00Z mutation-test projA
row 2026-09-19T11:00:00Z review        projB
row 2026-09-19T12:00:00Z mutation-test projC
row 2026-09-19T13:00:00Z review        projD
row 2026-09-19T16:00:00Z mutation-test projD
row 2026-09-19T14:00:00Z mutation-test projE
row 2026-09-19T14:30:00Z review        projE

out=$(python3 "$TOOL" --since 2026-09-19 --json 2>/dev/null)
get() { printf '%s' "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['$1'])" 2>/dev/null; }

[ "$(get leader_runs)" = "4" ] && pass "counts leader runs (4)" || bad "leader_runs=$(get leader_runs), expected 4"
[ "$(get follower_runs)" = "4" ] && pass "counts follower runs (4)" || bad "follower_runs=$(get follower_runs), expected 4"

# The pairing itself: only projA qualifies.
[ "$(get paired)" = "1" ] && pass "pairs only the follow-up inside the window, same project" \
  || bad "paired=$(get paired), expected 1 — projD is 3h later and projC/E have no leader before them"

# projD proves the window is enforced. Without it, any later run in the same project would count
# as a chain firing, which would report adoption that never happened.
[ "$(get unpaired)" = "3" ] && pass "a follow-up outside the window does not count as a pairing" \
  || bad "unpaired=$(get unpaired), expected 3"

# projE proves ORDER matters: a mutation-test that ran BEFORE the review cannot have been chained
# by it. Counting it would be the difference between "the chain works" and "the user ran it".
[ "$(get standalone_followers)" = "3" ] && pass "a follow-up that precedes its leader is standalone, not chained" \
  || bad "standalone_followers=$(get standalone_followers), expected 3 (projC, projD's late run, projE)"

[ "$(get pairing_rate_pct)" = "25" ] && pass "rate is paired/leaders (1 of 4 = 25%)" \
  || bad "pairing_rate_pct=$(get pairing_rate_pct), expected 25"

# Widening the window must move projD from unpaired to paired — proof the flag is load-bearing
# rather than decorative.
out=$(python3 "$TOOL" --since 2026-09-19 --window 240 --json 2>/dev/null)
[ "$(get paired)" = "2" ] && pass "--window widens the pairing (projD joins at 240m)" \
  || bad "with --window 240 paired=$(get paired), expected 2"

# The tool must work for any leader/follower pair, not just this one chain.
out=$(python3 "$TOOL" --since 2026-09-19 --leader mutation-test --follower review --window 60 --json 2>/dev/null)
[ "$(get paired)" = "1" ] && pass "--leader/--follower generalise to another chain (projE reversed)" \
  || bad "reversed pair gave paired=$(get paired), expected 1"

# Bad input must fail loudly rather than silently measuring the wrong window.
python3 "$TOOL" --since 2026-09-19 --window 0 >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "a non-positive window is refused" || bad "--window 0 was accepted"
python3 "$TOOL" --since "not-a-date" >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "an unparseable --since is refused" || bad "--since garbage was accepted"

# An empty log must say so, not print a confident 0%.
: > "$LOG"
python3 "$TOOL" --since 2026-09-19 >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "an empty runs.log exits non-zero instead of reporting 0%" \
  || bad "an empty log produced a success exit — a 0% that means 'no data' reads as 'never fires'"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
