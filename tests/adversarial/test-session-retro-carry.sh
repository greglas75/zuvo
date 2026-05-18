#!/usr/bin/env bash
# test-session-retro-carry.sh — Plan Task 6 (SC3).
# session-state.md must define a Retro State block + resume rule so a resumed
# multi-session run finalizes ONE coherent retro (stub OR full, never both).

S="$ROOT/shared/includes/session-state.md"
BASE=323   # session-state.md line count before this task (verified 2026-05-18)
# Plan estimate +20; raised to +25 after adversarial iter2 MANDATED two
# correctness wordings the estimate didn't foresee: (a) retro-session-id is
# the RUN identity inherited unchanged on resume — NOT the per-process
# session-id ("equals the resuming session" always-fails bug); (b) explicit
# "distinct runs keep distinct ids, no cross-run dedup / no data loss".
# Squeezing these out re-introduces the exact CRITICALs review caught. 24
# lines for the run-identity contract in a widely-loaded include is lean.
# Same user-approved disposition class as Task 2 (B-2). HARD gate at +25.
BUDGET=25

start_test "T6.1 Retro State block defines the carry fields"
if grep -qiE '^#+ .*Retro State' "$S"; then pass "Retro State section present"
else fail "T6.1" "no 'Retro State' section in session-state.md"; fi
for f in retro-session-id last-retro-status last-retro-friction; do
  grep -q "$f" "$S" && pass "field \`$f\` documented" || fail "T6.1" "missing field \`$f\`"
done

start_test "T6.2 resume rule: one execution-state session => exactly one retro"
# Scope to the Retro State section so prose elsewhere can't false-green it.
SEC=$(awk '/^#+ .*Retro State/{f=1;next} f&&/^#{1,3} /{exit} f' "$S")
if printf '%s' "$SEC" | grep -qiE 'retro-session-id' \
   && printf '%s' "$SEC" | grep -qiE 'resum' \
   && printf '%s' "$SEC" | grep -qiE 'one .*retro|single retro|exactly one|never both|finalize|upgrade|supersed'; then
  pass "section states the one-session-one-retro resume rule"
else
  fail "T6.2" "Retro State section does not state the resume coherence rule"
fi

start_test "T6.3 token-lean (<= +$BUDGET lines over base $BASE)"
NOW=$(wc -l < "$S"); MAX=$((BASE + BUDGET))
if [ "$NOW" -le "$MAX" ]; then pass "session-state.md $NOW <= $MAX (base $BASE +$BUDGET)"
else fail "T6.3" "session-state.md grew to $NOW, over budget $MAX"; fi

start_test "T6.4 sim: a full retro for the session supersedes a stub (no double-count)"
# Reuses Task 3 idempotency: stub then full at same skill+project+sha => the
# canonical predicate / retro-stub yields exactly one effective full record.
STUB="$ROOT/scripts/zuvo-home/retro-stub"
Z=$(mktemp -d); H=$(git -C "$ROOT" rev-parse --short HEAD)
# 1) checkpoint stub for the (still-running) session — assert it SUCCEEDED.
ZUVO_HOME="$Z" "$STUB" --status=CONTEXT_OUT --friction=context-out --skill=execute --project=demo >/dev/null 2>&1
assert_exit_code 0 "$?" "checkpoint stub emit exits 0 (script actually ran)"
s1=$(grep -c $'\tcontext-out\t' "$Z/retros.log" 2>/dev/null) || true
assert_eq 1 "${s1:-0}" "one CONTEXT_OUT stub written for the session"
# 2) the resumed run completes -> a FULL retro for the same key arrives.
printf 'RETRO: 2026-05-18T12:00:00Z\texecute\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t5\t40\t12\t3\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
# 3) a later stub/sweep for the same key MUST be an idempotent no-op (the
#    full retro supersedes). Assert the stub ran AND added nothing.
before=$(grep -c '^RETRO:' "$Z/retros.log")
ZUVO_HOME="$Z" "$STUB" --status=ABANDONED --friction=abandoned --skill=execute --project=demo >/dev/null 2>&1
assert_exit_code 0 "$?" "idempotent stub call exits 0 (ran, did not error)"
after=$(grep -c '^RETRO:' "$Z/retros.log")
assert_eq "$before" "$after" "no new stub added (full retro supersedes — idempotent)"
full=$(grep -c $'\tpipeline-heavy\t' "$Z/retros.log" 2>/dev/null) || true
[ "${full:-0}" -eq 1 ] && pass "exactly one FULL retro for the session (it supersedes)" \
  || fail "T6.4" "expected one full retro, got ${full:-0}"
rm -rf "$Z"
