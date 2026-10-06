#!/usr/bin/env bash
# test-provider-fanout-cap.sh — the fan-out cap (ZUVO_REVIEW_MAX_PROVIDERS, default 5)
# and the mode-validation guard that replaced the silent `*) FOCUS=code` fallback.
#
# WHY these two live in one file: both came out of the same measurement pass over
# ~/.zuvo/adversarial.log (2026-08-19). The cap exists because 9,613 adversarial
# invocations in 30 days fanned out to 43,228 provider calls; the mode guard exists
# because 45 of those runs were dispatched with the literal string `{MODE}` and were
# silently reviewed with the generic code rubric.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# attempted_of <json> -> the run's attempted_count ("?" when the output is not the driver's JSON). One copy:
# this extraction was pasted into eight cases.
attempted_of() {
  printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?"
}

# ─── Case 1: more providers than the cap → exactly N run, SAMPLED at random ──
# The cap samples rather than truncating (2026-09-05). Truncation retired the tail of the
# ranking permanently — ranks 6+ never executed once — and pinned whichever paid lane sat
# just inside the cap to 100% of reviews. So "which N" is deliberately NOT asserted here;
# the contract is the COUNT and the fact that kept + dropped partitions the input exactly.
# The cap is set EXPLICITLY rather than relying on the default: this case tests the
# MECHANISM, and coupling it to whatever the default happens to be made it fail for the
# wrong reason when the default moved 3 -> 5 (2026-09-04). CAP.0 below owns the default.
#
# The duplicate names in this list are load-bearing. Sampling by NAME kept every duplicate
# of a kept name, so this exact list came back with 5 of 5 under a cap of 3 — the cap
# silently ceased to exist. Real provider names are unique, which is why only a test with
# duplicates catches it. Sampling is index-based for that reason; do not "simplify" it.

start_test "CAP.1 5 providers, cap 3 → exactly 3 dispatched, kept+dropped partition the input"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=3 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success mock-success mock-fail mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1.err")
err=$(cat "$HERE/.tmp/cap1.err")
attempted=$(attempted_of "$out")
assert_eq "3" "$attempted" "attempted_count capped at 3 even with duplicate names"
assert_contains "$err" "Fan-out cap" "stderr announces the cap"
_kept=$(printf '%s' "$err" | sed -n 's/.*sampled at random (\([^)]*\)).*/\1/p' | head -1 | wc -w | tr -d ' ')
_drop=$(printf '%s' "$err" | sed -n 's/.*not running this time: \(.*\)/\1/p' | head -1 | wc -w | tr -d ' ')
assert_eq "3" "$_kept" "stderr lists exactly 3 kept"
assert_eq "2" "$_drop" "stderr lists exactly 2 dropped (kept+dropped = the 5 supplied)"

# ─── Case 1b: ranked mode is the reproducible escape hatch ───────────────────
# BSD sort has -R but not --random-source, so a seed cannot pin the sample. Anything that
# needs determinism (a test, a bisect) asks for the ranking explicitly instead.

start_test "CAP.1b ZUVO_REVIEW_PROVIDER_PICK=ranked → the first N, deterministically"
for _i in 1 2 3; do
  ZUVO_REVIEW_PROVIDER_PICK=ranked ZUVO_REVIEW_MAX_PROVIDERS=2 \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
    bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1b.err" >/dev/null
  printf '%s\n' "$(sed -n 's/.*sampled at random (\([^)]*\)).*/\1/p' "$HERE/.tmp/cap1b.err" | head -1)"
done | sort -u > "$HERE/.tmp/cap1b.sets"
assert_eq "1" "$(wc -l < "$HERE/.tmp/cap1b.sets" | tr -d ' ')" "ranked mode returns one stable set"
assert_contains "$(cat "$HERE/.tmp/cap1b.sets")" "mock-success mock-fail" "ranked mode keeps the first 2"

# ─── Case 1c: random mode actually varies ────────────────────────────────────
# Without this, a sampler that silently degraded back to head -n N would pass every other
# case in this file — the count assertions cannot tell truncation from sampling.

start_test "CAP.1c random mode produces more than one distinct set over 25 runs"
for _i in $(seq 1 25); do
  ZUVO_REVIEW_MAX_PROVIDERS=2 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
    bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1c.err" >/dev/null
  printf '%s\n' "$(sed -n 's/.*sampled at random (\([^)]*\)).*/\1/p' "$HERE/.tmp/cap1c.err" | head -1)"
done | sort -u > "$HERE/.tmp/cap1c.sets"
_variants=$(wc -l < "$HERE/.tmp/cap1c.sets" | tr -d ' ')
# 3 sets are possible; P(all 25 draws identical) = 2 * (1/3)^24, i.e. not a flake risk.
if [ "$_variants" -ge 2 ]; then
  pass "sampling varies ($_variants distinct sets in 25 runs)"
else
  fail "sampling varies" "every one of 25 runs returned the same set — sampler degraded to truncation"
fi

# ─── Case 0: the DEFAULT cap is 5 ────────────────────────────────────────────
# Raised from 3 on 2026-09-04. The old value was justified by "retains ~92% of
# CRITICAL-producing runs" — true, but about whether a run finds ANYTHING. Measured
# defect COVERAGE (20 diffs, Opus-judged, shared defect ids): 3 models see ~54% of 347
# distinct defects, 5 see ~66%, because 57% of each model's true findings are unique to it.

start_test "CAP.0 default cap is 5 (no override)"
out=$(env -u ZUVO_REVIEW_MAX_PROVIDERS ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success mock-success mock-success mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap0.err")
attempted=$(attempted_of "$out")
assert_eq "5" "$attempted" "6 providers, no override -> 5 dispatched"

start_test "CAP.0a zero is invalid and restores the default cap of 5"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=0 ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success mock-success mock-success mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap0a.err")
attempted=$(attempted_of "$out")
assert_eq "5" "$attempted" "zero does not disable provider dispatch"
assert_contains "$(cat "$HERE/.tmp/cap0a.err")" "ZUVO_REVIEW_MAX_PROVIDERS=0 is below its minimum of 1" "zero is reported as invalid"

# ─── Case 1d: pinned providers bypass the draw ───────────────────────────────
# agy (Gemini 3.8 Flash) is pinned by default because it is the highest measured MARGINAL
# contributor: 32 defects no other provider finds. A coin flip on the biggest unique
# contributor loses coverage nothing else can recover. The rest of the slots stay random,
# so this must NOT collapse back into "rank order always wins" — CAP.1c still has to pass.

start_test "CAP.1d pinned provider is in every sample; the rest still vary"
: > "$HERE/.tmp/cap1d.sets"
for _i in $(seq 1 20); do
  ZUVO_REVIEW_MAX_PROVIDERS=2 ZUVO_REVIEW_PIN_PROVIDERS="mock-empty" \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
    bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1d.err" >/dev/null
  sed -n 's/.*of 3 (\([^)]*\)).*/\1/p' "$HERE/.tmp/cap1d.err" | head -1 >> "$HERE/.tmp/cap1d.sets"
done
_runs=$(grep -c . "$HERE/.tmp/cap1d.sets" | tr -d ' ')
_with_pin=$(grep -c 'mock-empty' "$HERE/.tmp/cap1d.sets" | tr -d ' ')
_variants=$(sort -u "$HERE/.tmp/cap1d.sets" | grep -c . | tr -d ' ')
assert_eq "$_runs" "$_with_pin" "the pinned provider appears in every single sample"
if [ "$_variants" -ge 2 ]; then
  pass "the non-pinned slot still varies ($_variants distinct sets)"
else
  fail "the non-pinned slot still varies" "pinning froze the whole sample: $(sort -u "$HERE/.tmp/cap1d.sets" | tr '\n' '|')"
fi

start_test "CAP.1e ZUVO_REVIEW_PIN_PROVIDERS= (empty) pins nothing"
# The default is a value, not a hardcoded name, so it must be possible to switch off.
# Uses ${VAR-default}, not ${VAR:-default}: an explicitly EMPTY value has to mean "none",
# which :- would silently override back to the default.
ZUVO_REVIEW_MAX_PROVIDERS=2 ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1e.err" >/dev/null
_err=$(cat "$HERE/.tmp/cap1e.err")
case "$_err" in
  *"pinned:"*) fail "no pin announced when the pin list is empty" "stderr claimed a pin: $_err" ;;
  *)           pass "no pin announced when the pin list is empty" ;;
esac

# ─── Case 1m/1n: the pins fill (or overfill) the cap ──────────────────────────
# Every pin case above leaves a slot for the draw. When the pins alone reach the cap, providers.sh:858-866
# take the first <cap> pins in RANKING order and draw nothing: _ar_fill is 0 (or would be negative), so not
# one non-pinned lane may join. The default pin list has two names ("agy cursor-agent"), so a cap of 1 is
# exactly this case in the field. Deterministic — no draw happens — so one run per case is the proof.
# The kept pin answers and the dropped lanes are a failing and a missing one, so the outcome list shows
# which lanes ran and nothing else did.

start_test "CAP.1m two pins, cap 1 → only the first pin in ranking order runs, no lane is drawn"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=1 ZUVO_REVIEW_PIN_PROVIDERS="mock-empty mock-success" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-fail mock-success mock-empty" \
  bash "$ADV" --single --json --files "$EMPTY" 2>"$HERE/.tmp/cap1m.err"); rc=$?
assert_exit_code "0" "$rc" "the one pin kept answers"
assert_eq "  Fan-out cap: 1 of 3 (mock-success) — pinned: mock-success mock-empty, rest sampled at random; not running this time: mock-fail mock-empty" \
  "$(grep 'Fan-out cap:' "$HERE/.tmp/cap1m.err")" "kept: the first pin by rank; dropped: the second pin AND the non-pinned lane"
assert_eq "1" "$(attempted_of "$out")" "attempted_count is the cap, not the pin count"
assert_eq "mock-success:ok" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "only the kept pin was dispatched"

start_test "CAP.1n two pins, cap 2 → exactly the two pins, the non-pinned lane never joins"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=2 ZUVO_REVIEW_PIN_PROVIDERS="mock-empty mock-success" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-fail mock-success mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1n.err"); rc=$?
assert_exit_code "0" "$rc" "a pinned lane answers"
assert_eq "  Fan-out cap: 2 of 3 (mock-success mock-empty) — pinned: mock-success mock-empty, rest sampled at random; not running this time: mock-fail" \
  "$(grep 'Fan-out cap:' "$HERE/.tmp/cap1n.err")" "kept: both pins; dropped: the non-pinned lane (_ar_fill = 0)"
assert_eq "mock-success:ok,mock-empty:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" \
  "exactly the two pins were dispatched, in ranking order"

# ─── Case 1f: a provider with a failure record is benched, its slot reassigned ──
# The run-scoped auth cache never caught these: cursor-agent answered "You're out of usage"
# and codex-5.4 "gpt-5.4 is not supported ... ChatGPT account" — both exit 0 with the refusal
# in the BODY, so they land as "empty", and both kept being sampled for 281 and 206 runs.
# Every draw they won was a slot that ran nothing.

start_test "CAP.1f benched provider is excluded and its slot goes to a healthy one"
_hf="$HERE/.tmp/health-bench.tsv"
printf 'mock-empty\tunknown\t5\t%s\n' "$(date +%s)" > "$_hf"
ZUVO_PROVIDER_HEALTH_FILE="$_hf" ZUVO_REVIEW_MAX_PROVIDERS=2 ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1f.err" >/dev/null
_err=$(cat "$HERE/.tmp/cap1f.err")
assert_contains "$_err" "Benched" "stderr announces the bench"
case "$_err" in
  *"sampled at random"*mock-empty*|*"("*mock-empty*")"*)
     fail "benched provider is not sampled" "mock-empty still appeared: $_err" ;;
  *) pass "benched provider is not sampled" ;;
esac

start_test "CAP.1j a model swap clears the lane's inherited failure record"
# The ledger is keyed on the PAIR (lane, model), not the lane name. Measured 2026-09-09:
# openrouter-alt carried 4 failures earned as glm-5.3 and cursor-agent 4 as composer-2.5-fast;
# both models were replaced the same day, so the incoming ones would have been benched from
# their very first run for someone else's failures. A model swap is a different reviewer,
# not the same one after an outage.
_hfp="$HERE/.tmp/health-pair.tsv"
printf 'mock-empty\tOLD-MODEL\t9\t%s\n' "$(date +%s)" > "$_hfp"
ZUVO_PROVIDER_HEALTH_FILE="$_hfp" ZUVO_REVIEW_MAX_PROVIDERS=2 ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1j.err" >/dev/null
case "$(cat "$HERE/.tmp/cap1j.err")" in
  *Benched*) fail "record from a different model is ignored" "benched on another model's history" ;;
  *)         pass "record from a different model is ignored" ;;
esac

start_test "CAP.1k the ledger records the model alongside the lane"
# Without the model column the swap above cannot be detected at all.
#
# The assertion is on the FIRST FOUR fields, not on the row's total width: column 5 (the last
# outcome class) was added 2026-09-22 so the bench can tell a lane that blew the timeout from
# one that caught somebody else's 15-minute outage, and it is appended precisely so readers of
# the four-column format keep working. Pinning NF to 4 would have made every future additive
# column a test failure rather than a compatibility question.
_hfw="$HERE/.tmp/health-write.tsv"; : > "$_hfw"
ZUVO_PROVIDER_HEALTH_FILE="$_hfw" ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null >/dev/null
_shape=$(awk -F'\t' 'NR==1{ print (NF>=4 && $1!="" && $2!="" && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/) ? "ok" : "bad"; exit }' "$_hfw" 2>/dev/null || echo bad)
assert_eq "ok" "${_shape:-bad}" "rows start with <lane> <model> <fails> <epoch>"

start_test "CAP.1l legacy 3-column rows are dropped, never misread"
# A 3-column row predates the model column, so which model it describes is unknowable —
# honouring it would bench a lane on a history that may belong to a different reviewer.
_hfl="$HERE/.tmp/health-legacy.tsv"
printf 'legacy-lane\t9\t1\n' > "$_hfl"
ZUVO_PROVIDER_HEALTH_FILE="$_hfl" ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null >/dev/null
assert_eq "0" "$(grep -c '^legacy-lane' "$_hfl" | tr -d ' ')" "legacy row is gone after one run"

start_test "CAP.1g cooldown expiry lets a benched provider back in for one probe"
# A permanent ban would mean a restored subscription silently costs a reviewer forever.
# Each bench case seeds its OWN ledger: this one, 1h and 1i used to rewrite 1f's file, so they ran only in
# file order and a leftover row from one could decide the next.
_hfg="$HERE/.tmp/health-expiry.tsv"
printf 'mock-empty\tunknown\t5\t%s\n' "$(( $(date +%s) - 99999 ))" > "$_hfg"
ZUVO_PROVIDER_HEALTH_FILE="$_hfg" ZUVO_REVIEW_MAX_PROVIDERS=3 ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1g.err" >/dev/null
case "$(cat "$HERE/.tmp/cap1g.err")" in
  *Benched*) fail "stale bench expires" "still benched after the cooldown window" ;;
  *)         pass "stale bench expires" ;;
esac

start_test "CAP.1h all-benched fails OPEN rather than running nothing"
# If every candidate is benched the ledger is likelier wrong than the whole fleet being down.
now=$(date +%s)
_hfh="$HERE/.tmp/health-allbenched.tsv"
printf 'mock-success\tunknown\t9\t%s\nmock-fail\tunknown\t9\t%s\nmock-empty\tunknown\t9\t%s\n' "$now" "$now" "$now" > "$_hfh"
out=$(ZUVO_PROVIDER_HEALTH_FILE="$_hfh" ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1h.err")
attempted=$(attempted_of "$out")
assert_eq "3" "$attempted" "all-benched is ignored; every provider still runs"
assert_contains "$(cat "$HERE/.tmp/cap1h.err")" "every provider is benched" "stderr says why"

start_test "CAP.1i ZUVO_PROVIDER_BENCH=0 disables benching entirely"
_hfi="$HERE/.tmp/health-off.tsv"
printf 'mock-empty\tunknown\t9\t%s\n' "$(date +%s)" > "$_hfi"
ZUVO_PROVIDER_BENCH=0 ZUVO_PROVIDER_HEALTH_FILE="$_hfi" ZUVO_REVIEW_PIN_PROVIDERS="" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-empty" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap1i.err" >/dev/null
case "$(cat "$HERE/.tmp/cap1i.err")" in
  *Benched*) fail "bench can be switched off" "benched despite ZUVO_PROVIDER_BENCH=0" ;;
  *)         pass "bench can be switched off" ;;
esac

# ─── Case 2: the cap is a ceiling, not a floor ───────────────────────────────
# Fewer providers than the cap must pass through untouched and stay silent.

start_test "CAP.2 2 providers, below the cap → both run, no cap message"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap2.err")
err=$(cat "$HERE/.tmp/cap2.err")
attempted=$(attempted_of "$out")
assert_eq "2" "$attempted" "attempted_count unchanged below the cap"
case "$err" in
  *"Fan-out cap"*) fail "no cap message below the cap" "stderr mentioned the cap: $err" ;;
  *) pass "no cap message below the cap" ;;
esac

# ─── Case 3: ZUVO_REVIEW_MAX_PROVIDERS raises the ceiling ────────────────────

start_test "CAP.3 ZUVO_REVIEW_MAX_PROVIDERS=5 → all 5 run"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=5 \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success mock-success mock-success mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
attempted=$(attempted_of "$out")
assert_eq "5" "$attempted" "override raises the ceiling"

# ─── Case 4: a garbage override falls back to 3 rather than to zero ──────────
# A cap that parsed "" or "abc" as 0 would filter the provider list to nothing and
# turn every review into "no provider available" — a silent global outage.

start_test "CAP.4 non-numeric override → warns and uses the default, never 0"
# SIX providers, not four: the fallback cap must be OBSERVABLE. With fewer providers than
# the default the run is identical whether the bad value fell back to the default or to no
# cap at all, and the assertion would pass on a script that had silently stopped capping.
out=$(ZUVO_REVIEW_MAX_PROVIDERS=abc \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success mock-success mock-success mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap4.err")
err=$(cat "$HERE/.tmp/cap4.err")
attempted=$(attempted_of "$out")
assert_eq "5" "$attempted" "falls back to the default cap"
assert_contains "$err" "ZUVO_REVIEW_MAX_PROVIDERS='abc' is not a whole number" "stderr explains the bad value"

# ─── Case 4b: every shape of a bad cap, read exactly ─────────────────────────
# The cap is read through ar_env_int <var> <default> 1 (providers.sh:820; adversarial-review.sh:103-117):
# plain digits are the number (ar_decimal, leading zeros stripped — never octal); below the minimum of 1 → WARN
# "<var>=<n> is below its minimum of 1 — using <default>"; anything that is not plain digits (a sign, letters,
# trailing junk) → WARN "<var>='<value>' is not a whole number — using <default>". Read on a --dry-run (the cap
# runs before it, so nothing is dispatched) with ranked pick and no pins: the kept set is then the first N, so
# the Fan-out line (providers.sh:877, :879) and the Providers: line name the effective cap exactly.
CAP_SIX="mock-a mock-b mock-c mock-d mock-e mock-f"
CAP_FIVE_KEPT="  Fan-out cap: 5 of 6 sampled at random (mock-a mock-b mock-c mock-d mock-e); not running this time: mock-f"
CAP_HINT="  (size with ZUVO_REVIEW_MAX_PROVIDERS=N; ZUVO_REVIEW_PROVIDER_PICK=ranked for the old top-N behaviour)"
# cap_dry <driver args...> — "rc=<exit>" then every WARN, the Fan-out cap line, its sizing hint and the dry run's
# Providers: line, "|"-joined, of one ranked, pin-free --dry-run with stdin from /dev/null.
cap_dry() {
  local rc=0
  ZUVO_REVIEW_PROVIDER_PICK=ranked ZUVO_REVIEW_PIN_PROVIDERS="" \
    bash "$ADV" "$@" --dry-run < /dev/null > /dev/null 2> "$HERE/.tmp/capdry.err" || rc=$?
  printf 'rc=%s|%s' "$rc" "$(grep -E '^  WARN: |^  Fan-out cap: |^  \(size with |^Providers: ' "$HERE/.tmp/capdry.err" | tr '\n' '|' | sed 's/|$//')"
}

start_test "CAP.4b a negative cap is not a whole number: WARN, the default 5"
assert_eq "rc=0|  WARN: ZUVO_REVIEW_MAX_PROVIDERS='-2' is not a whole number — using 5|$CAP_FIVE_KEPT|$CAP_HINT|Providers: mock-a mock-b mock-c mock-d mock-e" \
  "$(ZUVO_REVIEW_MAX_PROVIDERS=-2 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_SIX" cap_dry --multi --files "$EMPTY")" \
  "-2: never read as 2 (the sign is not dropped), never as no cap — the default 5, said in a WARN"

start_test "CAP.4c a leading-zero cap is its decimal value, with no WARN"
assert_eq "rc=0|  Fan-out cap: 2 of 6 sampled at random (mock-a mock-b); not running this time: mock-c mock-d mock-e mock-f|$CAP_HINT|Providers: mock-a mock-b" \
  "$(ZUVO_REVIEW_MAX_PROVIDERS=02 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_SIX" cap_dry --multi --files "$EMPTY")" \
  "02 is a cap of 2, silently"
# 08 is the case providers.sh:819 names: an octal reading fails on it ("value too great for base") and used to
# leave no cap at all. It is 8 — above the 6 lanes, so no cap line and every lane stays.
assert_eq "rc=0|Providers: $CAP_SIX" \
  "$(ZUVO_REVIEW_MAX_PROVIDERS=08 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_SIX" cap_dry --multi --files "$EMPTY")" \
  "08 is a cap of 8 (decimal): six lanes are under it, all kept, no WARN"

start_test "CAP.4d zero, in any spelling, is below the minimum: WARN, the default 5"
for cap_v in 0 00; do
  assert_eq "rc=0|  WARN: ZUVO_REVIEW_MAX_PROVIDERS=0 is below its minimum of 1 — using 5|$CAP_FIVE_KEPT|$CAP_HINT|Providers: mock-a mock-b mock-c mock-d mock-e" \
    "$(ZUVO_REVIEW_MAX_PROVIDERS="$cap_v" ZUVO_REVIEW_TEST_PROVIDERS="$CAP_SIX" cap_dry --multi --files "$EMPTY")" \
    "$cap_v: read as 0, refused as below 1 — the WARN names the value as read"
done

start_test "CAP.4e a non-numeric cap: WARN naming the value, the default 5"
for cap_v in abc 2x; do
  assert_eq "rc=0|  WARN: ZUVO_REVIEW_MAX_PROVIDERS='$cap_v' is not a whole number — using 5|$CAP_FIVE_KEPT|$CAP_HINT|Providers: mock-a mock-b mock-c mock-d mock-e" \
    "$(ZUVO_REVIEW_MAX_PROVIDERS="$cap_v" ZUVO_REVIEW_TEST_PROVIDERS="$CAP_SIX" cap_dry --multi --files "$EMPTY")" \
    "'$cap_v': not plain digits — never read leniently as its digits"
done

# ─── Case 4f: --mode blind-audit sizes its PANEL instead ──────────────────────
# providers.sh:815-817: in --mode blind-audit the cap is ZUVO_BLIND_AUDIT_PANEL (default 3), read through the same
# ar_env_int; ZUVO_REVIEW_MAX_PROVIDERS is not read at all. And in every other mode the panel knob is not read.
CAP_BA="$HERE/.tmp/cap-ba"; mkdir -p "$CAP_BA"
printf 'f() { echo 1; }\n' > "$CAP_BA/p.sh"; printf '. ./p.sh\n[ "$(f)" = 1 ]\n' > "$CAP_BA/p.test.sh"
CAP_FIVE="mock-a mock-b mock-c mock-d mock-e"
CAP_BA_HINT="  (size with ZUVO_BLIND_AUDIT_PANEL=N; ZUVO_REVIEW_PROVIDER_PICK=ranked for the old top-N behaviour)"
CAP_BA_THREE="  Fan-out cap: 3 of 5 sampled at random (mock-a mock-b mock-c); not running this time: mock-d mock-e|$CAP_BA_HINT|Providers: mock-a mock-b mock-c"

start_test "CAP.4f blind-audit: the panel default is 3 and ZUVO_REVIEW_MAX_PROVIDERS is never read"
assert_eq "rc=0|$CAP_BA_THREE" \
  "$(unset ZUVO_BLIND_AUDIT_PANEL
     ZUVO_REVIEW_MAX_PROVIDERS=1 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_FIVE" cap_dry --mode blind-audit --production "$CAP_BA/p.sh" --test "$CAP_BA/p.test.sh")" \
  "panel unset, ZUVO_REVIEW_MAX_PROVIDERS=1: three lanes kept, the hint names ZUVO_BLIND_AUDIT_PANEL"
assert_eq "rc=0|$CAP_BA_THREE" \
  "$(unset ZUVO_BLIND_AUDIT_PANEL
     ZUVO_REVIEW_MAX_PROVIDERS=abc ZUVO_REVIEW_TEST_PROVIDERS="$CAP_FIVE" cap_dry --mode blind-audit --production "$CAP_BA/p.sh" --test "$CAP_BA/p.test.sh")" \
  "a bad ZUVO_REVIEW_MAX_PROVIDERS draws no WARN in this mode: it is not read"

start_test "CAP.4g blind-audit: ZUVO_BLIND_AUDIT_PANEL is read like the cap — leading zero, sign, letters"
assert_eq "rc=0|  Fan-out cap: 2 of 5 sampled at random (mock-a mock-b); not running this time: mock-c mock-d mock-e|$CAP_BA_HINT|Providers: mock-a mock-b" \
  "$(ZUVO_BLIND_AUDIT_PANEL=02 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_FIVE" cap_dry --mode blind-audit --production "$CAP_BA/p.sh" --test "$CAP_BA/p.test.sh")" \
  "panel 02: a panel of 2, no WARN"
for cap_v in -1 abc; do
  assert_eq "rc=0|  WARN: ZUVO_BLIND_AUDIT_PANEL='$cap_v' is not a whole number — using 3|$CAP_BA_THREE" \
    "$(ZUVO_BLIND_AUDIT_PANEL="$cap_v" ZUVO_REVIEW_TEST_PROVIDERS="$CAP_FIVE" cap_dry --mode blind-audit --production "$CAP_BA/p.sh" --test "$CAP_BA/p.test.sh")" \
    "panel '$cap_v': the WARN names ZUVO_BLIND_AUDIT_PANEL and the panel default 3"
done
assert_eq "rc=0|  WARN: ZUVO_BLIND_AUDIT_PANEL=0 is below its minimum of 1 — using 3|$CAP_BA_THREE" \
  "$(ZUVO_BLIND_AUDIT_PANEL=0 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_FIVE" cap_dry --mode blind-audit --production "$CAP_BA/p.sh" --test "$CAP_BA/p.test.sh")" \
  "panel 0: below the minimum, the panel default 3"
assert_eq "rc=0|$CAP_FIVE_KEPT|$CAP_HINT|Providers: mock-a mock-b mock-c mock-d mock-e" \
  "$(unset ZUVO_REVIEW_MAX_PROVIDERS
     ZUVO_BLIND_AUDIT_PANEL=1 ZUVO_REVIEW_TEST_PROVIDERS="$CAP_SIX" cap_dry --multi --files "$EMPTY")" \
  "--mode code: ZUVO_BLIND_AUDIT_PANEL=1 is not read — the global default 5 holds"

# ─── Case 5: --provider bypasses the cap entirely ────────────────────────────

start_test "CAP.5 explicit --provider is unaffected by the cap"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=1 \
  bash "$ADV" --provider mock-success --json --files "$EMPTY" 2>/dev/null)
attempted=$(attempted_of "$out")
assert_eq "1" "$attempted" "single explicit provider still runs"

# ─── Case 6: unknown --mode is a hard error, not a silent 'code' review ──────

start_test "MODE.1 unknown --mode → exit 2, names the valid set"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --single --mode refactor --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "2" "$ec" "exit code (caller error = 2)"
assert_contains "$err" "unknown --mode 'refactor'" "stderr names the bad mode"
assert_contains "$err" "code, test, tests, security" "stderr lists valid modes"
assert_contains "$err" "blind-audit" "stderr lists blind-audit among the valid modes"

# ─── Case 7: an unsubstituted placeholder gets its own diagnosis ─────────────
# `{MODE}` is the exact literal that reached the providers 45 times in one week;
# the generic "unknown mode" text would send the reader hunting for a typo instead
# of pointing at the template that failed to substitute.

start_test "MODE.2 literal {MODE} placeholder → exit 2 with substitution guidance"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --single --mode '{MODE}' --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "2" "$ec" "exit code (caller error = 2)"
assert_contains "$err" "never substituted" "stderr diagnoses the placeholder"
assert_contains "$err" "_ADV_MODE" "stderr points at the variable to set"

# ─── Case 8: every mode the skills actually pass still works ─────────────────
# Guards against the validation set drifting away from the call sites — the whole
# point of the guard is to catch typos, not to break `--mode article`.

for m in code test tests security spec plan audit migrate article; do
  start_test "MODE.3 --mode $m is accepted"
  ZUVO_PLAN_BUDGET_OFF=1 ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
    bash "$ADV" --single --mode "$m" --dry-run --files "$EMPTY" >/dev/null 2>&1
  ec=$?
  assert_ne "2" "$ec" "mode '$m' not rejected as unknown"
done

# blind-audit is deliberately NOT looped through --files above: it takes --production/--test only and
# refuses --files with exit 2 (tests/hooks/test-adversarial-blind-audit.sh, case A3) — so an exit 2
# there would say nothing about whether the MODE is known. It is checked through its own input.
start_test "MODE.3b --mode blind-audit is accepted (through --list-providers, its input-free form)"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --list-providers --mode blind-audit >/dev/null 2>&1
ec=$?
assert_eq "0" "$ec" "mode 'blind-audit' not rejected as unknown"

# ─── Case OR.1/OR.2: the OpenRouter lane retries throttling, not refusals ────
# A single 429 used to kill this lane for the whole run. On a host where the CLI reviewers
# fail at the ACCOUNT level (codex tier, gemini IneligibleTier) the OpenRouter lanes are the
# only reviewers there are, so one throttled request collapsed a cross-model review to a
# single model — reported honestly as status=partial, which is exactly why it went unnoticed.
# The fake upstream answers 429 twice and then succeeds: a lane without retry cannot pass.

_or_fake="$HERE/.tmp/orfake.py"
cat > "$_or_fake" <<'PYEOF'
import http.server, json, sys, threading, time
MODE=sys.argv[1]; N=[0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0))); N[0]+=1
        if MODE=='502html':
            b=b'<html><body>\x1b[31m502 Bad Gateway \xe2\x80\x94 \x9b2J\xc2\x9b\xe2\x80\xae retry\r</body></html>'; self.send_response(502)
            self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        if MODE=='429' and N[0]<3: code,body=429,{"error":{"message":"rate limited"}}
        elif MODE=='401': code,body=401,{"error":{"message":"bad key"}}
        else: code,body=200,{"choices":[{"message":{"content":"SEVERITY: WARNING\nCONFIDENCE: high\nFILE: x\nISSUE: y\nATTACK VECTOR: z\nSUGGESTED FIX: w\n"+("x"*1200)}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        b=json.dumps(body).encode(); self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
s=http.server.HTTPServer(('127.0.0.1',0),H); print(s.server_port, flush=True)
threading.Thread(target=s.serve_forever,daemon=True).start(); time.sleep(90)
PYEOF

start_test "OR.1 a 429 is retried inside the budget, the review still lands"
exec 9< <(python3 "$_or_fake" 429); read -u 9 _or_port
_out=$(printf 'diff --git a/x b/x\n+x\n' | ZUVO_OPENROUTER_BASE_URL="http://127.0.0.1:$_or_port/v1" \
  OPENROUTER_API_KEY="sk-or-test-fake" \
  ZUVO_ADV_OPENROUTER=1 ZUVO_REVIEW_TIMEOUT=40 bash "$ADV" --provider openrouter --mode code 2>&1)
exec 9<&-
case "$_out" in
  *"SEVERITY"*) pass "429 twice then 200 still produces a review" ;;
  *)            fail "429 twice then 200 still produces a review" "no review: $(printf '%s' "$_out" | tail -2)" ;;
esac

start_test "OR.2 a 401 fails fast — asking again cannot fix a bad key"
exec 9< <(python3 "$_or_fake" 401); read -u 9 _or_port
_t0=$(date +%s)
printf 'diff --git a/x b/x\n+x\n' | ZUVO_OPENROUTER_BASE_URL="http://127.0.0.1:$_or_port/v1" \
  OPENROUTER_API_KEY="sk-or-test-fake" \
  ZUVO_ADV_OPENROUTER=1 ZUVO_REVIEW_TIMEOUT=40 bash "$ADV" --provider openrouter --mode code >/dev/null 2>&1
_t1=$(date +%s); exec 9<&-
# Three attempts with 3s+6s of backoff would take >=9s; a fail-fast path returns in ~1s.
if [ $(( _t1 - _t0 )) -lt 8 ]; then pass "no retry on an auth refusal ($(( _t1 - _t0 ))s)"
else fail "no retry on an auth refusal" "took $(( _t1 - _t0 ))s — looks like it retried"; fi

start_test "OR.3 a non-2xx without an .error body is a failure, never a review"
# A gateway 502 HTML page after the retries used to fall through to the success path: curl
# exits 0, .error.message is absent, and the loop broke out as if a provider had answered.
exec 9< <(python3 "$_or_fake" 502html); read -u 9 _or_port
_out=$(printf 'diff --git a/x b/x\n+x\n' | ZUVO_OPENROUTER_BASE_URL="http://127.0.0.1:$_or_port/v1" \
  OPENROUTER_API_KEY="sk-or-test-fake" \
  ZUVO_ADV_OPENROUTER=1 ZUVO_REVIEW_TIMEOUT=40 bash "$ADV" --provider openrouter --mode code 2>&1)
exec 9<&-
# The lane's own stderr goes to the kept-failure directory, not to the caller's output, so
# read the diagnosis there. The empty-content guard already failed this lane before the fix;
# what changed is that the real cause is named instead of a generic "returned empty".
_or_kept=$(printf '%s\n' "$_out" | sed -n 's/.*stderr kept in \([^ .]*[^ ]*\)\. .*/\1/p' | head -1)
_or_kept="${_or_kept%.}"
case "$_out" in *"SEVERITY"*) _or_reviewed=1 ;; *) _or_reviewed=0 ;; esac
if [ "$_or_reviewed" -eq 0 ] && [ -n "$_or_kept" ] && [ -f "$_or_kept/provider_openrouter.stderr" ] \
   && python3 -c '
import sys
b = open(sys.argv[1], "rb").read()
# named status and printable ASCII only: no ESC/CR, no C1 (raw 0x9b or UTF-8 C2 9B), no bidi override
line = next((l for l in b.split(b"\n") if b"openrouter HTTP 502" in l), None)
sys.exit(0 if line is not None and all(0x20 <= c <= 0x7e for c in line) else 1)
' "$_or_kept/provider_openrouter.stderr"; then
  pass "HTTP 502 with an HTML body fails the lane and names the HTTP status"
else
  fail "HTTP 502 with an HTML body fails the lane and names the HTTP status" "reviewed=$_or_reviewed kept=[$_or_kept] out: $(printf '%s' "$_out" | tail -2)"
fi
