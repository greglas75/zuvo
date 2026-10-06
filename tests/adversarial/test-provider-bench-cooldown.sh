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
BENCH_ERR="$HERE/.tmp/bench.$$.err"
BENCH_HOME="$HERE/.tmp/bench-home.$$"
cleanup_bench() { rm -rf "$HF" "$BENCH_ERR" "$BENCH_HOME"; }
trap cleanup_bench EXIT

AGO=$(( $(date +%s) - 3600 ))   # one hour ago: past the 45-min soft window, inside the 6h hard one

seed() { printf '%b' "$1" > "$HF"; }

# bench_run [VAR=value ...] — a review over two mock lanes with the ledger as seeded; the VAR=value pairs
# override the defaults below. Leaves the driver's exit code in BENCH_RC and its stderr in $BENCH_ERR. Not
# meant for $( ): the exit code must reach the case, or "nothing benched" also reads true for a driver that
# crashed before printing anything.
bench_run() {
  env PATH="$MOCKS:$PATH" ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_BENCH=1 \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" ZUVO_REVIEW_TIMEOUT=5 "$@" \
    bash "$ADV" --multi --files "$EMPTY" >/dev/null 2>"$BENCH_ERR"
  BENCH_RC=$?
}
benched_line() { grep -F "Benched" "$BENCH_ERR" || true; }   # what the gate printed about benching
fail_row() { awk -F'\t' '$1 == "mock-fail" { print $3, $5 }' "${1:-$HF}" 2>/dev/null; }   # count + last outcome
# not_benched_and_ran <count after> — the positive half of "not benched": the run completed (mock-success
# answered, exit 0) and mock-fail WAS dispatched — its ledger row moved on to <count after> failures, `empty`.
not_benched_and_ran() {
  assert_exit_code "0" "$BENCH_RC" "the run completed: mock-success answered"
  assert_eq "$1 empty" "$(fail_row)" "mock-fail was dispatched and failed again (its row now: $1 failures, last 'empty')"
}
# benched_and_skipped <row before> — the lane was benched: named on the bench line, and never dispatched —
# its ledger row is the one seeded, unchanged.
benched_and_skipped() {
  assert_contains "$(benched_line)" "mock-fail" "mock-fail is named on the bench line"
  assert_eq "$1" "$(fail_row)" "mock-fail was not dispatched: its ledger row is unchanged ($1)"
}

# ─── 1. a fast empty, an hour old → soft window expired → lane is BACK ─────
start_test "bench.1 an 'empty' failure an hour old is no longer benched (soft cooldown)"
seed "mock-fail\tunknown\t4\t$AGO\tempty\n"
bench_run; line=$(benched_line)
assert_eq "" "$line" "a transient-class failure returns after the soft window, not after 6h"
not_benched_and_ran 5

# ─── 2. …but a TIMEOUT at the same age is still benched ───────────────────
start_test "bench.2 a 'timeout' failure at the same age keeps the full cooldown"
seed "mock-fail\tunknown\t4\t$AGO\ttimeout\n"
bench_run; line=$(benched_line)
assert_contains "$line" "mock-fail" "a lane that cannot finish inside the ceiling stays benched"
benched_and_skipped "4 timeout"

# ─── 3. …and so is a lane with a long failure streak ──────────────────────
start_test "bench.3 >= HARD_AFTER consecutive failures keeps the full cooldown"
seed "mock-fail\tunknown\t9\t$AGO\tempty\n"
bench_run; line=$(benched_line)
assert_contains "$line" "mock-fail" "9 failures in a row is not a bad minute"
benched_and_skipped "9 empty"

# ─── 4. a legacy 4-column row still parses, and takes the soft path ───────
start_test "bench.4 a row written before the outcome column takes the soft cooldown"
seed "mock-fail\tunknown\t4\t$AGO\n"
bench_run; line=$(benched_line)
assert_eq "" "$line" "no 5th column must not mean 'bench for six hours'"
not_benched_and_ran 5

# ─── 5. the row is still benched INSIDE the soft window ───────────────────
# Without this, cases 1 and 4 would also pass if benching stopped working altogether.
start_test "bench.5 the same failure is benched while the soft window is still open"
seed "mock-fail\tunknown\t4\t$(date +%s)\tempty\n"
bench_run; line=$(benched_line)
assert_contains "$line" "mock-fail" "a fresh failure is still benched"
benched_and_skipped "4 empty"

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

start_test "bench.7 a codex lane is benched under its OWN configured model before it has run"
# provider_model names what a codex lane RAN once it has (codex_cli_guard may lower it); before that —
# here, the bench — it is the lane's configured model. Swapped, the failing lane hides behind the other
# lane's model and the healthy one is benched in its place.
seed "codex-5.3\tgpt-6-sol\t3\t$(date +%s)\tauth\n"
line=$(PATH="$MOCKS:$PATH" ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_BENCH=1 \
  ZUVO_MODEL_CODEX_PRIMARY=gpt-6-sol ZUVO_MODEL_CODEX_ALT=gpt-6-luna \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 codex-5.4 mock-success" \
  bash "$ADV" --multi --dry-run --files "$EMPTY" 2>&1 >/dev/null | grep -F "Benched" || true)
assert_eq "codex-5.3" "${line##*: }" "only codex-5.3 (3 auth failures at gpt-6-sol) is benched"

# ─── 8. an exhausted plan (quota) keeps the full cooldown ─────────────────
# The cooldown choice in ar_bench_failing_lanes — `quota` is kimi's 5-hour window at best, its weekly one at
# worst (the function's own comment says so): a soft 45-min retry would spend a call on a refusal already known.
start_test "bench.8 a 'quota' failure an hour old keeps the full cooldown, like timeout and auth"
seed "mock-fail\tunknown\t4\t$AGO\tquota\n"
bench_run
benched_and_skipped "4 quota"

# ─── 9. the threshold is a count of CONSECUTIVE failures, from both sides ─
# ar_bench_failing_lanes — a row below ZUVO_PROVIDER_BENCH_THRESHOLD (default 3) is skipped whatever its
# class or age.
start_test "bench.9 threshold - 1 fresh timeouts: not benched; exactly the threshold: benched"
seed "mock-fail\tunknown\t2\t$(date +%s)\ttimeout\n"
bench_run
assert_eq "" "$(benched_line)" "2 failures (threshold 3) do not bench, even fresh and of the full-cooldown class"
not_benched_and_ran 3
seed "mock-fail\tunknown\t3\t$(date +%s)\ttimeout\n"
bench_run
benched_and_skipped "3 timeout"

start_test "bench.9b ZUVO_PROVIDER_BENCH_THRESHOLD moves the threshold"
seed "mock-fail\tunknown\t4\t$(date +%s)\ttimeout\n"
bench_run ZUVO_PROVIDER_BENCH_THRESHOLD=5
assert_eq "" "$(benched_line)" "4 failures under a threshold of 5 do not bench"
not_benched_and_ran 5

# ─── 10. a failure dated in the future does not bench ─────────────────────
# ar_bench_failing_lanes — a row written before the clock was set back has a NEGATIVE age, which passed
# `age < wait` for however far the clock had moved: the lane stayed benched past its cooldown.
start_test "bench.10 a record dated an hour in the future does not bench the lane"
seed "mock-fail\tunknown\t4\t$(( $(date +%s) + 3600 ))\ttimeout\n"
bench_run
assert_eq "" "$(benched_line)" "a future-dated failure is not a fresh one"
not_benched_and_ran 5

# ─── 11. malformed rows bench nothing and break nothing ───────────────────
# The ledger is a hand-editable TSV shared by every run on the host; a row it cannot read is skipped
# (ar_bench_failing_lanes: fewer than 4 fields, or a count that is not a number — `+0` makes it 0), never a crash
# of the review and never a bench. A timestamp that is not a number reads as epoch 0: older than any cooldown.
start_test "bench.11 short, non-numeric and garbage rows: no bench, and the review completes"
NOW=$(date +%s)
seed "mock-fail\t9\t$NOW\n"                               # 3 fields: the pre-model format
bench_run
assert_eq "" "$(benched_line)" "a 3-field row does not bench"
not_benched_and_ran 1
seed "mock-fail\tunknown\tmany\t$NOW\ttimeout\n"          # count is not a number
bench_run
assert_eq "" "$(benched_line)" "a non-numeric count does not bench"
not_benched_and_ran 1
seed "mock-fail\tunknown\t9\tyesterday\ttimeout\n"        # timestamp is not a number
bench_run
assert_eq "" "$(benched_line)" "a non-numeric timestamp does not bench"
not_benched_and_ran 10
seed "\n\ngarbage\n\t\t\n"                                 # blank, one-word and empty-field lines
bench_run
assert_eq "" "$(benched_line)" "garbage lines do not bench"
not_benched_and_ran 1

# ─── 12. an empty or missing ledger is not an error ───────────────────────
start_test "bench.12 an empty ledger benches nothing; a missing one (and its directory) is created"
: > "$HF"
bench_run
assert_eq "" "$(benched_line)" "an empty ledger benches nothing"
not_benched_and_ran 1
# ar_bench_failing_lanes: when the file's directory does not exist yet every ledger write failed SILENTLY,
# so nothing was ever benched. The directory and the file are made first.
bench_run ZUVO_PROVIDER_HEALTH_FILE="$BENCH_HOME/new-dir/health.tsv"
assert_exit_code "0" "$BENCH_RC" "the run completed"
assert_eq "1 empty" "$(fail_row "$BENCH_HOME/new-dir/health.tsv")" "the missing ledger was created and records this run"
