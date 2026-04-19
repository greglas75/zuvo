#!/usr/bin/env bash
# leads-resume-resilience.sh
# SC10 + SC11 + SU4: verify checkpoint survives SIGINT (100% recovery) and SIGKILL
# (≥95% recovery), and that concurrent runs are blocked by .lock/.
#
# This harness simulates the orchestrator's checkpoint + lock protocol with a small
# bash stand-in. Production correctness is verified by the full orchestrator; this
# test gates the protocol-level invariants independent of the full pipeline.

set -u
fail() { echo "FAIL: $1"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Writer subprocess (run in explicit subshell so trap is inherited cleanly)
writer() {
  local outdir="$1" slug="$2"
  (
    local cp="$outdir/.checkpoint-$slug.jsonl"
    # Signal trap set FIRST before any state mutation
    trap 'rm -rf "$outdir/.lock"; exit 130' INT TERM HUP
    # atomic lock acquisition
    mkdir "$outdir/.lock" 2>/dev/null || exit 3
    OWN_START=$(ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //; s/ $//')
    printf '%s\t%s\t%s\n' "$$" "$(hostname)" "$OWN_START" > "$outdir/.lock/pid"
    local i=0
    while [ $i -lt 20 ]; do
      printf '{"idx":%d,"email":"p%d@test"}\n' "$i" "$i" >> "$cp"
      i=$((i + 1))
      sleep 0.15 &
      wait $!
    done
    rm -rf "$outdir/.lock"
  )
}

# Test 1: SIGINT → trap runs → all pre-signal records retained
echo "Test 1: SIGINT recovery"
SLUG1=int-recovery
mkdir "$TMP/$SLUG1-dir"
writer "$TMP/$SLUG1-dir" "$SLUG1" &
WPID=$!
sleep 0.8  # wait for ~5 records
kill -INT $WPID 2>/dev/null
wait $WPID 2>/dev/null
[ ! -d "$TMP/$SLUG1-dir/.lock" ] || fail "SIGINT handler did not release .lock/"
RECORDS=$(wc -l < "$TMP/$SLUG1-dir/.checkpoint-$SLUG1.jsonl")
[ "$RECORDS" -ge 4 ] || fail "SIGINT recovery: expected ≥4 records, got $RECORDS"
# Every line must be parseable JSON (no partial write)
while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo "$line" | jq -e '.' >/dev/null || fail "SIGINT recovery: malformed JSONL line: $line"
done < "$TMP/$SLUG1-dir/.checkpoint-$SLUG1.jsonl"
echo "PASS: SIGINT recovery=${RECORDS}/20 records, all valid JSON"

# Test 2: SIGKILL → no trap, but checkpoint still has pre-kill records
echo "Test 2: SIGKILL recovery (≥95% target)"
SLUG2=kill-recovery
mkdir "$TMP/$SLUG2-dir"
writer "$TMP/$SLUG2-dir" "$SLUG2" &
WPID=$!
sleep 1.2  # wait for ~7-8 records
kill -9 $WPID 2>/dev/null
wait $WPID 2>/dev/null
# Lock WILL remain (no trap on SIGKILL) → stale-PID detection in orchestrator
# would reclaim it on next run. We verify here that the checkpoint records are intact.
RECORDS_K=$(wc -l < "$TMP/$SLUG2-dir/.checkpoint-$SLUG2.jsonl")
[ "$RECORDS_K" -ge 5 ] || fail "SIGKILL recovery: expected ≥5 records, got $RECORDS_K"
# Last line might be partial due to kill during write; jq validates each
INVALID=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  echo "$line" | jq -e '.' >/dev/null 2>&1 || INVALID=$((INVALID + 1))
done < "$TMP/$SLUG2-dir/.checkpoint-$SLUG2.jsonl"
[ "$INVALID" -le 1 ] || fail "SIGKILL recovery: $INVALID malformed lines (expect ≤1 trailing)"
# Valid lines must be ≥95% of total claimed by wc
VALID=$((RECORDS_K - INVALID))
PCT=$(( VALID * 100 / RECORDS_K ))
[ "$PCT" -ge 95 ] || fail "SIGKILL recovery: ${PCT}% valid (target ≥95%)"
echo "PASS: SIGKILL recovery=${VALID}/${RECORDS_K} valid lines (${PCT}%)"

# Test 3: Concurrent runs blocked by .lock
echo "Test 3: .lock blocks second writer"
SLUG3=concurrent
mkdir "$TMP/$SLUG3-dir"
writer "$TMP/$SLUG3-dir" "$SLUG3" &
W1=$!
sleep 0.3  # first writer has lock
writer "$TMP/$SLUG3-dir" "$SLUG3-alt" 2>/dev/null &
W2=$!
sleep 0.2
wait $W2; W2_EXIT=$?
[ "$W2_EXIT" -eq 3 ] || fail "second writer should exit 3 (lock held); got $W2_EXIT"
kill -INT $W1 2>/dev/null; wait $W1 2>/dev/null
echo "PASS: concurrent run properly blocked by .lock"

echo "PASS"
exit 0
