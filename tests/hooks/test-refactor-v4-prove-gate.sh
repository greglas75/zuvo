#!/usr/bin/env bash
# v4 prove fields: prove.test_quality + prove.split_coverage in hooks/lib/refactor-gate-lib.sh.
#
# Why they are enforced in bash and not in prose — measured 2026-08-12 across 413 COMPLETE
# refactor contracts on this machine:
#     prove.blind_audit / prove.adversarial (a hook blocks on them)   96-97% recorded
#     prove.test_quality (only prose called it HARD)                   3% recorded (33% in Aug)
# The gate is the entire difference. prove.split_coverage exists because rs_be PR #291 split a
# service into 7 modules holding 2586 lines and shipped with zero specs for them, past blind
# audit, adversarial, mutation Grade A, review APPROVE and ship — no gate asked about the files
# a refactor CREATES, because characterization can only cover the surface that existed before it.
#
# THE CASE THAT MATTERS MOST IS THE FIRST ONE. The first version of this change enforced both
# fields at pre-commit, where they cannot possibly be filled: Phase 3.5 commits at SKILL.md:1022,
# Phase 3.6 fills them at :1049. That deadlocked the default path of every refactor. Case 1 is
# the regression test for that, and it must never go red.
#
# Assertions check the OUTPUT, not only the exit code: an earlier draft passed its BLOCK cases on
# Linux while the hook was actually dying in _mtime and never reaching the v4 code at all.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

mkdir -p "$TMP/r/zuvo/contracts" "$TMP/r/zuvo/audits"; cd "$TMP/r" || exit 1
: > zuvo/audits/tq.md          # the real test-audit report the honest cases point at
git init -q; git config user.email t@t; git config user.name t
cat > .git/hooks/pre-commit <<H
#!/bin/sh
exec "$GATE" pre-commit
H
chmod +x .git/hooks/pre-commit

# contract VERSION_LITERAL TEST_QUALITY SPLIT_COVERAGE MODULES_CSV STAGE
# VERSION_LITERAL goes in verbatim so a quoted "4" and an absent key are both expressible.
contract(){
  local ver="$1" tq="$2" sc="$3" mods="$4" stage="${5:-PHASE-3}" vline="" mline="[]"
  [ "$ver" != "none" ] && vline="\"version\":$ver,"
  if [ -n "$mods" ]; then
    mline="[$(printf '%s' "$mods" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}}')]"
  fi
  cat > zuvo/contracts/refactor-aaaa1111.json <<J
{ $vline "file":"app.ts", "stage":"$stage", "scope_fence":["app.ts"],
  "modules_created": $mline,
  "prove": { "characterization":"green:a:2u", "blind_audit":"clean:strict",
             "adversarial":"clean", "findings_disposition":"none",
             "test_quality":"$tq", "split_coverage":"$sc" } }
J
}
# Exercise the unit directly: the pre-push entry needs a real remote + stdin refs, which would
# test git plumbing rather than this gate.
push(){ ZUVO_AI_RUN=1 ZUVO_GATE_MODE=pre-push sh -c '. "$1"; refactor_prove_v4_check "app.ts"' _ "$LIB" 2>&1; }
pushrc(){ push >/dev/null 2>&1; echo $?; }
commitrc(){ echo "x$RANDOM" >> app.ts; git add app.ts
  ZUVO_AI_RUN=1 git commit -q -m t >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && git reset -q >/dev/null 2>&1; echo $rc; }

chmod +x "$GATE" "$LIB" 2>/dev/null
echo "=== v4 prove gate ==="

# 1. NO DEADLOCK AT PRE-COMMIT. This is the Phase 3.5 commit: fields not yet fillable.
contract 4 "not_run" "not_run" ""
[ "$(commitrc)" -eq 0 ] && ok "pre-commit with unfilled v4 fields: PASS (no deadlock — the regression case)" \
                        || bad "DEADLOCK: pre-commit blocks the commit that must precede Phase 3.6"

# 2. …and the same contract IS judged at pre-push, where both fields are knowable.
out=$(push)
case "$out" in *"prove.test_quality='not_run'"*) ok "pre-push: unfilled test_quality BLOCKs (with its own message)" ;;
  *) bad "pre-push did not block unfilled test_quality; output: ${out:-<empty>}" ;; esac
[ "$(pushrc)" -ne 0 ] && ok "pre-push returns non-zero" || bad "pre-push returned 0 while printing BLOCK"

# 3. Vocabulary: PASS/WARN/N/A are outcomes; an invented string is not. "WARN:substituted-inline"
#    is the exact value a field run made up, which is why this asserts on shape, not emptiness.
#    split_coverage is VALID here on purpose, so test_quality is the only possible reason to
#    block. A mutation probe caught this: with both fields wrong, removing test_quality's blocking
#    flag entirely still left the case green, because split_coverage was failing in parallel and
#    carrying the exit code. Each field needs one case where it is the sole cause.
contract 4 "WARN:substituted-inline" "N/A" ""
case "$(push)" in *"prove.test_quality="*) ok "invented test_quality value BLOCKs (message)" ;;
  *) bad "invented test_quality value accepted" ;; esac
[ "$(pushrc)" -ne 0 ] && ok "…and it is the SOLE cause of a non-zero exit" \
                      || bad "test_quality prints BLOCK but does not set the blocking flag"
contract 4 "WARN:B:zuvo/audits/tq.md" "N/A" ""
[ "$(pushrc)" -eq 0 ] && ok "WARN + N/A on a refactor that created nothing: PASS" || bad "declared WARN treated as failure"
# …and the report must EXIST. A claim pointing at a file that was never written is the
# substituted gate wearing a passing badge.
contract 4 "PASS:A:zuvo/audits/never-written.md" "N/A" ""
case "$(push)" in *"does not exist"*) ok "PASS naming a nonexistent report: BLOCK (proof-of-dispatch)" ;;
  *) bad "a fabricated report path was accepted" ;; esac
contract 4 "PASS:A:/etc/passwd" "N/A" ""
[ "$(pushrc)" -ne 0 ] && ok "absolute report path: BLOCK (containment)" || bad "absolute path accepted"
#    …and the traversal half of the same containment check, which had no coverage at all until a
#    CQ audit named it. Same bug class as the path traversal this range fixes in fleet-retro-pull.py.
contract 4 "PASS:A:zuvo/audits/../../../etc/passwd" "N/A" ""
[ "$(pushrc)" -ne 0 ] && ok "relative path containing '..': BLOCK (containment)" || bad "'..' traversal accepted"
#    Bare N/A is a live accept-branch of the vocabulary and was never exercised.
contract 4 "N/A" "N/A" ""
[ "$(pushrc)" -eq 0 ] && ok "bare 'N/A' test_quality: PASS (no report needed)" || bad "bare N/A rejected"
#    A push that touches no file in this contract's fence must be left alone entirely.
contract 4 "not_run" "not_run" ""
offrc=$(ZUVO_AI_RUN=1 ZUVO_GATE_MODE=pre-push sh -c '. "$1"; refactor_prove_v4_check "unrelated.ts"' _ "$LIB" >/dev/null 2>&1; echo $?)
[ "$offrc" -eq 0 ] && ok "push touching no fenced file: not judged" || bad "gate judged a contract this push never touched"

# 4. THE FALSIFIABILITY CROSS-CHECK — this is what makes split_coverage more than a wish.
#    rs_be #291 is the fixture: 7 modules created, claim says none.
M7='a.ts,b.ts,c.ts,d.ts,e.ts,f.ts,g.ts'
contract 4 "PASS:A:zuvo/audits/tq.md" "N/A" "$M7"
case "$(push)" in *"'N/A' is false"*) ok "7 modules created + split_coverage=N/A: BLOCK (the #291 shape)" ;;
  *) bad "the rs_be #291 shape still passes — the cross-check is not wired" ;; esac
contract 4 "PASS:A:zuvo/audits/tq.md" "3/3:fixed-in-run" "$M7"
case "$(push)" in *"disagrees with modules_created"*) ok "count mismatch (3 claimed, 7 created): BLOCK" ;;
  *) bad "numerator is not cross-checked against modules_created" ;; esac
contract 4 "PASS:A:zuvo/audits/tq.md" "7/7:fixed-in-run" "$M7"
[ "$(pushrc)" -eq 0 ] && ok "7/7 matching modules_created: PASS" || bad "honest complete contract was blocked"
contract 4 "PASS:A:zuvo/audits/tq.md" "7/5:2-backlogged-out-of-fence" "$M7"
[ "$(pushrc)" -eq 0 ] && ok "7/5 with a named backlog disposition: PASS (declared gap, not silent)" \
                      || bad "a declared partial gap was blocked"
contract 4 "PASS:A:zuvo/audits/tq.md" "TODO" "$M7"
[ "$(pushrc)" -ne 0 ] && ok "free-text split_coverage: BLOCK" || bad "free text accepted as a coverage claim"

# 5. Version handling. The guard is the rollout: v3 runs are judged by v3 rules so an in-flight
#    refactor cannot be blocked by a field its own skill version never knew about.
contract 3 "not_run" "not_run" "$M7"
[ "$(pushrc)" -eq 0 ] && ok "v3 contract: exempt (self-migrating rollout, no flag day)" || bad "v3 blocked — flag day"
contract none "not_run" "not_run" "$M7"
[ "$(pushrc)" -eq 0 ] && ok "contract with no version key: exempt" || bad "missing version key blocked"
contract '"4"' "not_run" "not_run" ""
[ "$(pushrc)" -ne 0 ] && ok "version as the STRING \"4\": still enforced (quote-tolerant parse)" \
                      || bad "\"4\" as a string silently disarms the gate"
contract 5 "not_run" "not_run" ""
[ "$(pushrc)" -ne 0 ] && ok "version 5: enforced (>=, not ==)" || bad "a future version disarms the gate"

# 6. COMPLETE is the state a finished refactor is in at push time. Skipping it here would mean
#    the field is enforced nowhere at all — refactor_gate_check already skips terminal stages.
contract 4 "not_run" "not_run" "" COMPLETE
[ "$(pushrc)" -ne 0 ] && ok "stage=COMPLETE at pre-push: still enforced" \
                      || bad "COMPLETE skipped at pre-push — then these fields are enforced nowhere"

# 7. The mandated test commit must not be blocked by the sibling scope gate. Phase 3.6 Step 0
#    orders `test(<scope>):` for created modules; a new spec is in no fence by construction.
contract 4 "PASS:A:zuvo/audits/tq.md" "7/7:fixed-in-run" "$M7"
mkdir -p src
echo "x" > src/new-module.spec.ts; git add src/new-module.spec.ts
ZUVO_AI_RUN=1 git commit -q -m "test(result): cover the created module" >/dev/null 2>&1
rc=$?; [ $rc -ne 0 ] && git reset -q >/dev/null 2>&1
[ "$rc" -eq 0 ] && ok "the mandated test(<scope>): commit is not blocked by the scope gate" \
                || bad "scope gate blocks the test commit Phase 3.6 Step 0 demands"

# 7b. FAIL-OPEN ON A NON-ARRAY modules_created. The walker takes the first `[` after the key; with
#    `"modules_created": null` it used to fall through to the NEXT array in the file (progress[])
#    and count THOSE as created modules — a false BLOCK on an honest push, in a file whose stated
#    contract is fail-OPEN. Found by an independent behaviour audit, reproduced, then anchored.
cat > zuvo/contracts/refactor-aaaa1111.json <<'J'
{ "version":4, "file":"app.ts", "stage":"PHASE-3", "scope_fence":["app.ts"],
  "modules_created": null,
  "progress": ["phase1: done", "phase2: done", "phase3: done"],
  "prove": { "characterization":"green:a:2u", "blind_audit":"clean:strict", "adversarial":"clean",
             "findings_disposition":"none", "test_quality":"PASS:A:zuvo/audits/tq.md", "split_coverage":"N/A" } }
J
[ "$(pushrc)" -eq 0 ] && ok "modules_created=null does not borrow the next array (fail-open held)" \
                      || bad "FALSE BLOCK: a sibling array was counted as created modules"

# 8. DECOY-KEY SPOOF. The agent writes this contract, so field extraction must be scoped to the
#    `prove` object. Reading the whole file and taking the first hit let a sibling object above
#    `prove` answer for it — verified 2026-08-13: this exact contract passed with every real
#    value at `not_run`, defeating the v4 fields AND the pre-existing v3 ones. An agent-typable
#    bypass of the repo's only agent-independent bind.
cat > zuvo/contracts/refactor-aaaa1111.json <<'J'
{ "version":4, "file":"app.ts", "stage":"PHASE-3", "scope_fence":["app.ts"],
  "previous_attempt": { "test_quality": "PASS:A:zuvo/audits/tq.md", "split_coverage": "7/7:fixed-in-run" },
  "modules_created": ["a.ts","b.ts","c.ts","d.ts","e.ts","f.ts","g.ts"],
  "prove": { "characterization":"green:a:2u", "blind_audit":"clean:strict", "adversarial":"clean",
             "findings_disposition":"none", "test_quality":"not_run", "split_coverage":"not_run" } }
J
case "$(push)" in *"prove.test_quality='not_run'"*) ok "decoy object above prove does NOT answer for it (v4)" ;;
  *) bad "DECOY SPOOF: a sibling key satisfied the gate while prove.* was not_run" ;; esac

#    Same spoof against the v3 fields, which read through the same extractor. This case guards a
#    gate this change did not add — it inherited it, and inherited its hole.
cat > zuvo/contracts/refactor-aaaa1111.json <<'J'
{ "version":3, "file":"app.ts", "stage":"PHASE-3", "scope_fence":["app.ts"],
  "notes": { "blind_audit": "clean:strict", "adversarial": "clean", "characterization": "green:a:2u" },
  "prove": { "characterization":"not_run", "blind_audit":"not_run", "adversarial":"not_run",
             "findings_disposition":"none" } }
J
v3out=$(ZUVO_AI_RUN=1 sh -c '. "$1"; refactor_gate_check "app.ts"' _ "$LIB" 2>&1)
case "$v3out" in *"prove.blind_audit='not_run'"*) ok "decoy object does NOT answer for the v3 prove fields either" ;;
  *) bad "DECOY SPOOF (v3): sibling keys satisfied blind_audit/adversarial/characterization" ;; esac

#    …and the extractor must still read a legitimately nested prove value correctly.
cat > zuvo/contracts/refactor-aaaa1111.json <<'J'
{ "version":4, "file":"app.ts", "stage":"PHASE-3", "scope_fence":["app.ts"],
  "modules_created": ["a.ts","b.ts"],
  "prove": { "characterization":"green:a:2u", "blind_audit":"clean:strict", "adversarial":"clean",
             "findings_disposition":"none", "detail": { "note": "nested object inside prove" },
             "test_quality":"PASS:A:zuvo/audits/tq.md", "split_coverage":"2/2:fixed-in-run" } }
J
[ "$(pushrc)" -eq 0 ] && ok "a nested object INSIDE prove does not break extraction" \
                      || bad "the scoped extractor mis-parses a nested object inside prove"

# 9. FAIL-OPEN survives every parse problem — this file's standing contract.
cat > zuvo/contracts/refactor-aaaa1111.json <<'J'
{ "version":"four", "file":"app.ts", "stage":"PHASE-3", "scope_fence":["app.ts"],
  "prove": { "characterization":"green:a:1u", "blind_audit":"clean:strict", "adversarial":"clean" } }
J
[ "$(pushrc)" -eq 0 ] && ok "unparseable version: FAIL-OPEN" || bad "unparseable version blocked"
printf 'not json at all' > zuvo/contracts/refactor-aaaa1111.json
[ "$(pushrc)" -eq 0 ] && ok "garbage contract: FAIL-OPEN" || bad "garbage contract blocked"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
