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
field_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }   # field_of <meta> <key> -> its value

# ─── 1. a provider that ran and gave nothing is NAMED, not collapsed ──────
start_test "fe.1 a provider that answered with nothing is recorded by name"
H="$FE/tried"; mkdir -p "$H"
ZUVO_HOME="$H" ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" ZUVO_PROVIDER_BENCH=0 \
  bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1
m=$(meta_of "$H")
# The field itself, exactly: a silent exit 1 is `empty` for that lane — never `none` or `interrupted`.
assert_eq "mock-fail:empty" "$(field_of "$m" provider_outcomes)" "the outcome is the provider's own verdict, by name"

# ─── 2. the dispatch list is recorded, so the kill case is reconstructable ─
start_test "fe.2 meta records which providers were dispatched"
assert_contains "$m" "dispatched=" "dispatched= field present"
assert_contains "$m" "dispatched=mock-fail" "…and names the provider that started"

# ─── 3. THE REGRESSION: killed mid-flight must not read as 'none' ─────────
# Reproduced the way it actually happens — the process is killed while a provider is still
# running, which is what an outer `timeout` or a reaped process group does. With the old code
# this wrote `provider_outcomes=none`, indistinguishable from case 1.
start_test "fe.3 a run killed mid-flight reads as 'interrupted', never 'none'"
H2="$FE/killed"; mkdir -p "$H2" "$FE/bin"
# The lane marks the moment it STARTS — the driver has added it to the dispatch list by then — and then
# hangs as the sleeper itself (exec), so the kill lands mid-flight by a handshake, not after a guessed delay.
cat > "$FE/bin/mock-hang-marked" <<'EOF'
#!/bin/sh
: > "$FE_STARTED"
cat > /dev/null
exec sleep 120
EOF
chmod +x "$FE/bin/mock-hang-marked"
rm -f "$FE/started"
FE_STARTED="$FE/started" PATH="$FE/bin:$PATH" ZUVO_HOME="$H2" ZUVO_REVIEW_TEST_PROVIDERS="mock-hang-marked" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=120 bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1 &
adv_pid=$!
for _ in $(seq 1 300); do [ -e "$FE/started" ] && break; sleep 0.1; done
if [ -e "$FE/started" ]; then pass "premise: the lane was running when the run was killed"
else fail "premise: the lane never started within 30 s — the kill below is not mid-flight"; fi
kill -TERM "$adv_pid" 2>/dev/null
wait "$adv_pid" 2>/dev/null
m2=$(meta_of "$H2")
# Empty when the kill path wrote no evidence at all — a different failure, and it fails here too.
assert_eq "interrupted" "$(field_of "$m2" provider_outcomes)" "a killed run's outcome is exactly 'interrupted'"
assert_eq "mock-hang-marked" "$(field_of "$m2" dispatched)" "…and the lane it was waiting on is on the dispatch list"

# ─── 4. nothing dispatched at all still reads as 'none' ───────────────────
# The word keeps its original meaning for the case it was right about; otherwise the fix would
# just move the ambiguity somewhere else.
# A whole run cannot reach that case — evidence is kept only when a lane left stderr behind, and only a
# dispatched lane does — so preserve_failure_evidence itself is called, as the EXIT trap calls it, with the
# state each case leaves: nothing dispatched, dispatched but killed before any outcome, an outcome recorded.
start_test "fe.4 'none' survives for the case it actually describes"
. "$ROOT/tests/lib/adversarial-driver.sh"   # preserve_failure_evidence lives in a module: read the whole program
if adv_driver_source "$ADV" > "$FE/program.sh"; then
  fe_fns="$(grep '^AR_NUM_CAP=' "$FE/program.sh"
    for f in ar_decimal ar_env_int preserve_failure_evidence; do
      awk -v f="$f" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$FE/program.sh"
    done)"
  # pfe <case> <dispatched> <outcomes> -> provider_outcomes= of the meta.txt the function writes for a lane
  # that left a stderr file behind.
  pfe() {
    local h="$FE/pfe-$1"; mkdir -p "$h/tmp"; : > "$h/tmp/provider_mock-x.stderr"
    # shellcheck disable=SC2034  # every global below is read by the eval'd preserve_failure_evidence
    ( eval "$fe_fns" || exit 97
      ZUVO_HOME="$h"; JSON_TMPDIR="$h/tmp"; RUN_ID="fe4-$1"; REVIEW_MODE=code; MULTI_MODE=single
      PROVIDERS=mock-x; PROVIDER_TIMEOUT=120; PROVIDER_COUNT=0; FAILURE_EVIDENCE_DIR=""
      DISPATCHED_LIST="$2"; PROVIDER_OUTCOMES="$3"
      preserve_failure_evidence )
    field_of "$(cat "$h/adversarial-failures/fe4-$1/meta.txt" 2>/dev/null)" provider_outcomes
  }
  assert_eq "none" "$(pfe none "" "")" "nothing dispatched: 'none'"
  assert_eq "interrupted" "$(pfe killed mock-x "")" "dispatched, no outcome yet: 'interrupted'"
  assert_eq "mock-x:empty" "$(pfe judged mock-x mock-x:empty)" "an outcome recorded: the outcome itself"
else
  fail "the program text could not be assembled (reason above)"
fi
