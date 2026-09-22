#!/usr/bin/env bash
# test-provider-bench-cooldown.sh — the health ledger benches a lane after N consecutive
# failures. This covers HOW LONG, which until 2026-09-22 was a single flat 6h for every kind
# of failure.
#
# What that cost, measured on the fleet ledger that day: codex-5.3 and codex-5.4 both went from
# `ok` to `empty` in the SAME second (09:36:46), each returning in 6s — two different models,
# one instant, i.e. a CLI/account hiccup, and it lasted ~15 minutes. Both OpenAI lanes were then
# held out of every review for six hours; a probe an hour later answered in 11s. Six of fourteen
# (lane, model) pairs were benched at that moment and two of them were healthy.
#
# So the cooldown is now sized by WHY the lane failed:
#   timeout / auth        full cooldown — a lane that cannot finish inside PROVIDER_TIMEOUT is
#                         structurally wrong for this pipeline, not unlucky
#   >= HARD_AFTER in a row  full cooldown — 32 consecutive empties is not a bad minute
#   anything else         soft cooldown — a fast empty is usually somebody else's outage
#
# The 5th column (last outcome) is what makes that distinction possible, and it is OPTIONAL:
# rows written before it existed must still parse, and must take the SOFT path — the safe
# direction, since a still-broken lane re-benches itself on its next failure.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

HF="$HERE/.tmp/health.$$.tsv"
cleanup_bench() { rm -f "$HF"; }
trap cleanup_bench EXIT

AGO=$(( $(date +%s) - 3600 ))   # one hour ago: past the 45-min soft window, inside the 6h hard one

seed() { printf '%b' "$1" > "$HF"; }

# Runs a review over two mock lanes and returns whatever the gate printed about benching.
bench_line() {
  PATH="$MOCKS:$PATH" ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_BENCH=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" ZUVO_REVIEW_TIMEOUT=5 \
    bash "$ADV" --multi --files "$EMPTY" 2>&1 >/dev/null | grep -F "Benched" || true
}

# ─── 1. a fast empty, an hour old → soft window expired → lane is BACK ─────
start_test "bench.1 an 'empty' failure an hour old is no longer benched (soft cooldown)"
seed "mock-fail\tunknown\t4\t$AGO\tempty\n"
line=$(bench_line)
assert_eq "" "$line" "a transient-class failure returns after the soft window, not after 6h"

# ─── 2. …but a TIMEOUT at the same age is still benched ───────────────────
start_test "bench.2 a 'timeout' failure at the same age keeps the full cooldown"
seed "mock-fail\tunknown\t4\t$AGO\ttimeout\n"
line=$(bench_line)
assert_contains "$line" "mock-fail" "a lane that cannot finish inside the ceiling stays benched"

# ─── 3. …and so is a lane with a long failure streak ──────────────────────
start_test "bench.3 >= HARD_AFTER consecutive failures keeps the full cooldown"
seed "mock-fail\tunknown\t9\t$AGO\tempty\n"
line=$(bench_line)
assert_contains "$line" "mock-fail" "9 failures in a row is not a bad minute"

# ─── 4. a legacy 4-column row still parses, and takes the soft path ───────
start_test "bench.4 a row written before the outcome column takes the soft cooldown"
seed "mock-fail\tunknown\t4\t$AGO\n"
line=$(bench_line)
assert_eq "" "$line" "no 5th column must not mean 'bench for six hours'"

# ─── 5. the row is still benched INSIDE the soft window ───────────────────
# Without this, cases 1 and 4 would also pass if benching stopped working altogether.
start_test "bench.5 the same failure is benched while the soft window is still open"
seed "mock-fail\tunknown\t4\t$(date +%s)\tempty\n"
line=$(bench_line)
assert_contains "$line" "mock-fail" "a fresh failure is still benched"

# ─── 6. the writer records the outcome class ──────────────────────────────
# The sizing above is worthless if nothing ever writes column 5.
start_test "bench.6 record_provider_health writes the outcome class as column 5"
: > "$HF"
PATH="$MOCKS:$PATH" ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_BENCH=1 \
ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" ZUVO_REVIEW_TIMEOUT=5 \
  bash "$ADV" --multi --files "$EMPTY" >/dev/null 2>&1
cols=$(awk -F'\t' '$1=="mock-fail"{print NF; exit}' "$HF")
outcome=$(awk -F'\t' '$1=="mock-fail"{print $5; exit}' "$HF")
assert_eq "5" "${cols:-0}" "the failing lane's row carries five fields"
assert_ne "" "${outcome:-}" "…and the fifth one names the outcome"
