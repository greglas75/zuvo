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
out=$(printf '%b\n' "$RL" | ZUVO_HOME="$Z" "$ARUN" 2>&1); rc=$?
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
