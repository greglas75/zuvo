#!/usr/bin/env bash
# test-failure-evidence-meta.sh — the failure ledger must say WHICH kind of nothing happened.
#
# `~/.zuvo/adversarial-failures/<run>/meta.txt` is what anyone diagnosing a lane reads. Its
# `provider_outcomes` field used to collapse two opposite situations into one word:
#
#   every provider was tried and returned nothing   -> a verdict about the providers
#   the run was KILLED before results were collected -> no verdict about anything
#
# preserve_failure_evidence runs from the EXIT trap, so an outer `timeout`, a reaped process
# group or a Ctrl-C arrives with PROVIDER_OUTCOMES still empty and wrote `none` — the same word
# the first case writes. Measured over the saved evidence: 93 of 259 directories said `none`,
# and one of them holds a provider stderr reporting 11088 input / 3175 output tokens. Real work,
# discarded, filed as "nobody answered". A lane diagnosed from that ledger is diagnosed from
# runs where it was never actually judged.
#
# DISPATCHED_LIST separates them: it is appended as each provider STARTS.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

FE="$ADV_TEST_HOME/fe"; mkdir -p "$FE"

meta_of() { # meta_of <home> -> the newest run's meta.txt
  local d; d=$(ls -dt "$1"/adversarial-failures/*/ 2>/dev/null | head -1)
  [ -n "$d" ] && cat "$d/meta.txt" 2>/dev/null
}

# ─── 1. a provider that ran and gave nothing is NAMED, not collapsed ──────
start_test "fe.1 a provider that answered with nothing is recorded by name"
H="$FE/tried"; mkdir -p "$H"
ZUVO_HOME="$H" ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1
m=$(meta_of "$H")
assert_contains "$m" "mock-fail:" "the outcome names the provider, not a bare word"
case "$m" in
  *provider_outcomes=none*)        assert_eq "named outcome" "none" "a tried provider must not read as 'none'" ;;
  *provider_outcomes=interrupted*) assert_eq "named outcome" "interrupted" "a tried provider must not read as 'interrupted'" ;;
  *) assert_eq "ok" "ok" "outcome is a per-provider verdict" ;;
esac

# ─── 2. the dispatch list is recorded, so the kill case is reconstructable ─
start_test "fe.2 meta records which providers were dispatched"
assert_contains "$m" "dispatched=" "dispatched= field present"
assert_contains "$m" "dispatched=mock-fail" "…and names the provider that started"

# ─── 3. THE REGRESSION: killed mid-flight must not read as 'none' ─────────
# Reproduced the way it actually happens — the process is killed while a provider is still
# running, which is what an outer `timeout` or a reaped process group does. With the old code
# this wrote `provider_outcomes=none`, indistinguishable from case 1.
start_test "fe.3 a run killed mid-flight reads as 'interrupted', never 'none'"
H2="$FE/killed"; mkdir -p "$H2"
ZUVO_HOME="$H2" ZUVO_REVIEW_TEST_PROVIDERS="mock-hang" ZUVO_PROVIDER_BENCH=0 \
  ZUVO_REVIEW_TIMEOUT=120 bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1 &
adv_pid=$!
# Wait for a provider to actually start, then kill the whole run.
for _ in $(seq 1 60); do
  [ -n "$(ls -d "$H2"/adversarial-failures/*/ 2>/dev/null)" ] && break
  pgrep -P "$adv_pid" >/dev/null 2>&1 && break
  sleep 0.5
done
sleep 2
kill -TERM "$adv_pid" 2>/dev/null
wait "$adv_pid" 2>/dev/null
m2=$(meta_of "$H2")
if [ -z "$m2" ]; then
  # No evidence written at all is a different failure, and worth saying out loud rather than
  # passing quietly on an assertion that never ran.
  assert_eq "meta.txt written" "nothing written" "the kill path must still leave evidence"
else
  case "$m2" in
    *provider_outcomes=none*) assert_eq "interrupted" "none" "a killed run must not claim no provider was tried" ;;
    *) assert_eq "ok" "ok" "killed run does not read as 'none'" ;;
  esac
fi

# ─── 4. nothing dispatched at all still reads as 'none' ───────────────────
# The word keeps its original meaning for the case it was right about; otherwise the fix would
# just move the ambiguity somewhere else.
start_test "fe.4 'none' survives for the case it actually describes"
src=$(cat "$ADV")
assert_contains "$src" "printf 'provider_outcomes=none" "the none branch still exists"
assert_contains "$src" 'elif [[ -n "${DISPATCHED_LIST:-}" ]]; then' "…guarded by the dispatch list"
