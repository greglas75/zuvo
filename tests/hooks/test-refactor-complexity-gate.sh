#!/usr/bin/env bash
# v5 effectiveness fields: prove.complexity_before + prove.complexity_reduced in
# hooks/lib/refactor-gate-lib.sh (inside refactor_prove_v4_check, version >= 5).
#
# Why they are enforced in bash and not in prose — measured 2026-08-20 across 101 split-ish
# refactor commits in 4 repos over 14 days: 87% reduced the worst function, 13% halved the FILE
# while the worst function stayed intact or GREW (exerciseDesignMapper.ts −614 lines, maxfn
# 103→103; kano-advanced.helpers.ts 63→87; income-timing-integrity.scorer.ts split TWICE, 43→45
# both times). Every safety gate passed on all of them: characterization, blind audit,
# adversarial, split_coverage — all ask "did it break?", none asked "did it help?".
#
# The criterion is the worst FUNCTION, never file LOC — file LOC is exactly the number the 13%
# optimized. The baseline is recorded in Phase 1 (before any edit) and cross-checked against the
# after-measurement, so faking "reduced" requires lying twice, backwards in time — the same
# principle split_coverage borrows from modules_created.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

bash -n "$LIB" 2>/dev/null && ok "gate lib parses" || bad "gate lib does not parse"

mkdir -p "$TMP/r/zuvo/contracts" "$TMP/r/zuvo/audits"; cd "$TMP/r" || exit 1
: > zuvo/audits/tq.md

# contract VERSION TYPE COMPLEXITY_BEFORE COMPLEXITY_REDUCED
# v4 prove fields are filled with honest passing values so ONLY the v5 checks are under test.
contract(){
  cat > zuvo/contracts/refactor-bbbb2222.json <<J
{ "version":$1, "file":"app.ts", "type":"$2", "stage":"COMPLETE", "scope_fence":["app.ts"],
  "modules_created": [],
  "prove": { "characterization":"green:a:2u", "blind_audit":"clean:strict",
             "adversarial":"clean", "findings_disposition":"none",
             "test_quality":"N/A", "split_coverage":"N/A",
             "complexity_before":"$3", "complexity_reduced":"$4" },
  "progress": [ {"type":"note"} ] }
J
}
# Exercise the unit directly, exactly as the sibling v4 test does.
push(){ ZUVO_AI_RUN=1 ZUVO_GATE_MODE=pre-push sh -c '. "$1"; refactor_prove_v4_check "app.ts"' _ "$LIB" 2>&1; }
pushrc(){ push >/dev/null 2>&1; echo $?; }

# 1. VERSION GUARD — the rollout contract. A v4 contract knows nothing of these fields; an
#    in-flight run started by an older skill must never be blocked by them.
contract 4 SPLIT_FILE "not_run" "not_run"
[ "$(pushrc)" = "0" ] && ok "v4 contract: complexity fields not enforced (self-migrating rollout)" \
  || bad "v4 contract blocked on a field its version never knew about"

# 2. TYPE SCOPE — MOVE promises no reduction and is not judged.
contract 5 MOVE "not_run" "not_run"
[ "$(pushrc)" = "0" ] && ok "v5 MOVE: not judged (only SPLIT_FILE/GOD_CLASS/SIMPLIFY promise reduction)" \
  || bad "v5 MOVE was blocked — type scope is wrong"

# 3. The honest passing case.
contract 5 SPLIT_FILE "maxfn:100,branches:298,loc:889" "reduced:maxfn:100->47,branches:298->140"
[ "$(pushrc)" = "0" ] && ok "reduced with matching baseline and a real 53% drop: passes" \
  || bad "the honest reduced case was blocked: $(push | head -2)"

# 4. THE CASE THIS GATE EXISTS FOR — file halved, worst function intact, still claims reduced.
contract 5 SPLIT_FILE "maxfn:103,branches:298,loc:889" "reduced:maxfn:103->103,branches:298->199"
out=$(push); rc=$?
[ "$rc" != "0" ] && printf '%s' "$out" | grep -q "not >=10% smaller" \
  && ok "maxfn 103->103 claiming reduced: BLOCKED (the exerciseDesignMapper case)" \
  || bad "the 103->103 relocation passed as reduced"

# 5. Boundary: exactly 10% is reduced; 9% is not.
contract 5 GOD_CLASS "maxfn:100,branches:1,loc:1" "reduced:maxfn:100->90,branches:1->1"
[ "$(pushrc)" = "0" ] && ok "boundary: 100->90 (exactly 10%) passes" || bad "100->90 blocked"
contract 5 GOD_CLASS "maxfn:100,branches:1,loc:1" "reduced:maxfn:100->91,branches:1->1"
[ "$(pushrc)" != "0" ] && ok "boundary: 100->91 (9%) blocked" || bad "100->91 passed as reduced"

# 6. Missing baseline — a baseline recorded after the work is not a baseline.
contract 5 SPLIT_FILE "not_run" "reduced:maxfn:100->47"
out=$(push); rc=$?
[ "$rc" != "0" ] && printf '%s' "$out" | grep -q "complexity_before" \
  && ok "missing Phase 1 baseline: BLOCKED" || bad "missing baseline sailed through"

# 7. Baseline mismatch — the lie must be told twice, backwards in time.
contract 5 SPLIT_FILE "maxfn:120,branches:1,loc:1" "reduced:maxfn:100->47,branches:1->1"
out=$(push); rc=$?
[ "$rc" != "0" ] && printf '%s' "$out" | grep -q "disagrees with prove.complexity_before" \
  && ok "before-value 100 vs baseline 120: BLOCKED (cross-check)" \
  || bad "a re-derived flattering baseline was accepted"

# 8. not_run after the work — the field cannot be skipped on a split intent.
contract 5 SIMPLIFY "maxfn:80,branches:1,loc:1" "not_run"
[ "$(pushrc)" != "0" ] && ok "complexity_reduced=not_run on SIMPLIFY: BLOCKED" \
  || bad "not_run passed — the gate is optional again"

# 9. essential: the honest disclosure path — needs a reason, then passes WITHOUT reduction.
contract 5 SPLIT_FILE "maxfn:43,branches:1,loc:1" "essential:maxfn:43->45:reason=ordered first-match band cascade, order IS the algorithm"
[ "$(pushrc)" = "0" ] && ok "essential with a named reason: passes without reduction (43->45 disclosed)" \
  || bad "honest essential was blocked: $(push | head -2)"
contract 5 SPLIT_FILE "maxfn:43,branches:1,loc:1" "essential:maxfn:43->45"
out=$(push); rc=$?
[ "$rc" != "0" ] && printf '%s' "$out" | grep -q "reason=" \
  && ok "essential WITHOUT a reason: BLOCKED (an unexplained essential is a skipped gate)" \
  || bad "reason-less essential passed"

# 10. already-small: only honest when there was nothing to reduce.
contract 5 SPLIT_FILE "maxfn:38,branches:1,loc:1" "already-small:maxfn:38->35"
[ "$(pushrc)" = "0" ] && ok "already-small at baseline 38: passes" || bad "already-small at 38 blocked"
contract 5 SPLIT_FILE "maxfn:80,branches:1,loc:1" "already-small:maxfn:80->78"
out=$(push); rc=$?
[ "$rc" != "0" ] && printf '%s' "$out" | grep -q "<=50" \
  && ok "already-small at baseline 80: BLOCKED (80 was the thing to reduce)" \
  || bad "already-small at 80 passed"

# 11. Unknown verdict vocabulary.
contract 5 SPLIT_FILE "maxfn:100,branches:1,loc:1" "improved:maxfn:100->47"
[ "$(pushrc)" != "0" ] && ok "unknown verdict 'improved': BLOCKED (closed vocabulary)" \
  || bad "an invented verdict passed"

# 12. Mode gate — the whole check is pre-push only (v4 contract deadlock lesson).
contract 5 SPLIT_FILE "not_run" "not_run"
rc=$(ZUVO_AI_RUN=1 ZUVO_GATE_MODE=pre-commit sh -c '. "$1"; refactor_prove_v4_check "app.ts"' _ "$LIB" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "pre-commit mode: not enforced (fields are only knowable at push time)" \
  || bad "enforced at pre-commit — that deadlocks every split refactor"

# 13. Fence miss — a contract whose fence this push does not touch is not judged.
contract 5 SPLIT_FILE "not_run" "not_run"
rc=$(ZUVO_AI_RUN=1 ZUVO_GATE_MODE=pre-push sh -c '. "$1"; refactor_prove_v4_check "other.ts"' _ "$LIB" >/dev/null 2>&1; echo $?)
[ "$rc" = "0" ] && ok "push not touching the fence: not judged" || bad "blocked a push outside the fence"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
