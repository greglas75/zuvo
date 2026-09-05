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
attempted=$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?")
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
attempted=$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?")
assert_eq "5" "$attempted" "6 providers, no override -> 5 dispatched"

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

# ─── Case 2: the cap is a ceiling, not a floor ───────────────────────────────
# Fewer providers than the cap must pass through untouched and stay silent.

start_test "CAP.2 2 providers, below the cap → both run, no cap message"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$HERE/.tmp/cap2.err")
err=$(cat "$HERE/.tmp/cap2.err")
attempted=$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?")
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
attempted=$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?")
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
attempted=$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?")
assert_eq "5" "$attempted" "falls back to the default cap"
assert_contains "$err" "not a positive integer" "stderr explains the bad value"

# ─── Case 5: --provider bypasses the cap entirely ────────────────────────────

start_test "CAP.5 explicit --provider is unaffected by the cap"
out=$(ZUVO_REVIEW_MAX_PROVIDERS=1 \
  bash "$ADV" --provider mock-success --json --files "$EMPTY" 2>/dev/null)
attempted=$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("attempted_count","?"))' 2>/dev/null || echo "?")
assert_eq "1" "$attempted" "single explicit provider still runs"

# ─── Case 6: unknown --mode is a hard error, not a silent 'code' review ──────

start_test "MODE.1 unknown --mode → exit 2, names the valid set"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --single --mode refactor --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "2" "$ec" "exit code (caller error = 2)"
assert_contains "$err" "unknown --mode 'refactor'" "stderr names the bad mode"
assert_contains "$err" "code, test, tests, security" "stderr lists valid modes"

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
