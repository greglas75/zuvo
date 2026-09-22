#!/usr/bin/env bash
# test-append-retro-contract.sh — the binding WRITE↔READ contract.
# append-retro output MUST satisfy append-runlog's gate for the SAME
# skill+project (the asymmetry that left 12 execute runs un-loggable on
# 2026-05-29: drifted retros could never match the NF==17 gate). Also asserts
# append-retro REJECTS the corruption classes at the source.

ARET="$ROOT/scripts/zuvo-home/append-retro"
ARUN="$ROOT/scripts/zuvo-home/append-runlog"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }
T="2026-05-29T00:00:00Z"

start_test "append-retro output PASSES append-runlog gate (write↔read contract)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=TestProj --code-type=DATA_SERVICE \
  --friction=other --context-gap=none --turns=4 --tool-calls=120 \
  --files-read=18 --files-modified=6 --blind-audit=clean:strict \
  --adversarial=2findings --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 0 "$?" "append-retro emits a full retro"
RL=$(printf '%s\texecute\tTestProj\t-\t-\tPASS\t1\t1-tasks\tredo\tmain\ttestsha\t-\t-' "$T")
printf '%b\n' "$RL" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1; rc=$?
assert_exit_code 0 "$rc" "append-runlog accepts the run line (retro matched the gate)"
n=$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)
assert_eq 1 "$n" "exactly one runs.log row written"

start_test "append-retro REJECTS empty SKILL / empty FRICTION"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --project=X --friction=other >/dev/null 2>&1
assert_exit_code 2 "$?" "empty --skill rejected"
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=X >/dev/null 2>&1
assert_exit_code 2 "$?" "empty --friction rejected"

start_test "append-retro REJECTS embedded TAB in a field"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project="$(printf 'a\tb')" --friction=other >/dev/null 2>&1
assert_exit_code 2 "$?" "TAB in --project rejected (would corrupt TSV)"

start_test "append-retro REJECTS stub friction on the full-retro path"
Z=$(_z)
for fr in abandoned context-out partial-recovery degraded-autolog; do
  ZUVO_HOME="$Z" "$ARET" --skill=execute --project=X --friction="$fr" >/dev/null 2>&1
  rc=$?
  assert_exit_code 2 "$rc" "--friction=$fr rejected on full path"
done

start_test "append-retro REJECTS a FUTURE --date (forgery class)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=X --friction=other --date=2099-01-01T00:00:00Z >/dev/null 2>&1
assert_exit_code 2 "$?" "future --date rejected"

# ─── N/A must be answerable for gate columns the skill does not have ─────────
# 2026-08-06: the BLIND_AUDIT enum had no `N/A`, so a skill with no blind-audit
# step could not answer truthfully. Measured over 246 retros: 164 blind-audit
# verdicts, 108 of them (66%) from skills whose SKILL.md never mentions the step
# (ship 42, review 34, test-audit 23) — `clean:degraded` the popular choice.
# Agents were not inventing; the validator REJECTED the truth, so they picked the
# safest-sounding value. The column became unusable for analysis and was about to
# ship fleet-wide as a `blind_audit_ran` metric. CODESIFT and ROUTING already
# allowed N/A, which is exactly why those two columns read sanely.
start_test "append-retro accepts N/A for gate columns a skill does not have"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=ship --project=P --code-type=MIXED \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=0 --blind-audit=N/A \
  --adversarial=N/A --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 0 "$?" "blind-audit=N/A and adversarial=N/A accepted"

start_test "N/A lands in the log as N/A, not silently rewritten"
grep -q "$(printf 'N/A\tN/A\tindexed')" "$Z/retros.log" 2>/dev/null \
  && pass "the N/A pair is written verbatim (a reader can tell 'no such step' from 'skipped')" \
  || fail "N/A round-trip" "$(tail -1 "$Z/retros.log" 2>/dev/null | cut -c1-160)"

start_test "a junk gate value is STILL rejected (N/A did not open the enum)"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=ship --project=P --code-type=MIXED \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=0 --blind-audit=probably-fine \
  --adversarial=N/A --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 2 "$?" "unrecognised blind-audit value still exits 2"

# ─── the protocol's vocabulary and the script's enum must not drift apart ─────
# `Nfindings:preserved` is defined in retrospective.md field 15 as its OWN verdict:
# a behavior-preserving refactor draws findings on patterns it MOVED but did not
# introduce, fixing them would change behavior, and `Nfindings` would claim they
# drove a fix. The case statement accepted `*findings` and nothing after it, so
# every run that followed the documented protocol exited 2 here — and since
# append-runlog gates on a matching retro, that run lost its telemetry entirely.
# Four separately-mined change proposals pointed at this one line before anyone
# reconciled the doc against the script (2026-09-22).
start_test "append-retro accepts the documented Nfindings:preserved verdict"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=refactor --project=P --code-type=PURE_FUNCTION \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=1 --blind-audit=N/A \
  --adversarial=3findings:preserved --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 0 "$?" "a behavior-preserving refactor can record its real verdict"

start_test "and it lands verbatim, distinguishable from a plain Nfindings"
grep -q "3findings:preserved" "$Z/retros.log" 2>/dev/null \
  && pass "preserved-disposition findings stay distinct from findings that drove fixes" \
  || fail "Nfindings:preserved round-trip" "$(tail -1 "$Z/retros.log" 2>/dev/null | cut -c1-160)"

start_test "the suffix did not open the enum to anything ending in a colon"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=refactor --project=P --code-type=PURE_FUNCTION \
  --friction=other --context-gap=none --turns=1 --tool-calls=1 \
  --files-read=1 --files-modified=1 --blind-audit=N/A \
  --adversarial=3findings:mostly-fine --codesift=indexed --routing=ok \
  --sha7=testsha --date="$T" >/dev/null 2>&1
assert_exit_code 2 "$?" "an invented disposition suffix is still rejected"
