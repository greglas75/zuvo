#!/usr/bin/env bash
# Contract for ~/.zuvo/refactor-contract — the one command that reads and advances a refactor
# CONTRACT.
#
# Every case here is drawn from something the fleet actually did across 1,010 contracts on disk:
# four invented stage spellings, 92 contracts with no stage at all, sidecar files offered as resume
# candidates, and 134 abandoned contracts that made `continue` unusable. The gate cases matter most
# — a contract that records a phase without its evidence is what a resumed run, the commit gate and
# the retro all go on to read as fact.
#
# bash 3.2-compatible (macOS default). Accumulate-and-report.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/refactor-contract"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$BIN" ] || { bad "scripts/zuvo-home/refactor-contract does not exist"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R/.git" "$R/src" "$R/zuvo/contracts"

mkcontract() { # mkcontract <name> <python-mutation>
  python3 - "$R/zuvo/contracts/$1" "$2" <<'PY'
import json, sys
path, mut = sys.argv[1], sys.argv[2]
c = {"version": 5, "file": "src/order.service.ts", "type": "EXTRACT_METHODS", "mode": "full",
     "stage": "PHASE-1", "cq_before": {"score": "11/18"}, "modules_created": [],
     "prove": {k: "not_run" for k in
               ("characterization", "blind_audit", "adversarial", "regression_red",
                "test_quality", "split_coverage", "complexity_before", "complexity_reduced")},
     "progress": []}
c["prove"]["findings_disposition"] = "pending"
if mut:
    exec(mut)
json.dump(c, open(path, "w"), indent=1)
PY
}

run() { ( cd "$R" && python3 "$BIN" "$@" ) > "$TMP/out" 2> "$TMP/err"; }

# ── 1. the gate: a phase cannot be entered without the evidence it depends on ─
mkcontract "refactor-aaaaaaaa.json" ""
run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" stage PHASE-4; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'REFUSED' "$TMP/err"; then
  pass "a phase whose prerequisites are unproven is REFUSED"
else
  bad "PHASE-4 accepted with every prove field at not_run (exit=$rc)"
fi
grep -q 'prove.characterization' "$TMP/err" \
  && pass "the refusal names which evidence is missing" \
  || bad "refusal does not say what is missing"
grep -q 'refactor-contract prove' "$TMP/err" \
  && pass "the refusal says how to satisfy it" \
  || bad "refusal gives no way forward"

# The stage must NOT have been written by a refused call.
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$R/zuvo/contracts/refactor-aaaaaaaa.json'))['stage']=='PHASE-1' else 1)" \
  && pass "a refused advance leaves the contract untouched" \
  || bad "the contract was mutated by a call that was refused"

# ── 2. recording the evidence unlocks the phase ───────────────────────────────
for f in characterization regression_red test_quality; do
  run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" prove "$f" "PASS 41 tests, 0 failures"
done
run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" prove findings_disposition "3 fixed, 1 preserved"
run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" stage PHASE-4; rc=$?
[ "$rc" -eq 0 ] && pass "the same advance succeeds once the evidence is recorded" \
  || bad "PHASE-4 still refused after its prerequisites were proven (exit=$rc): $(head -3 "$TMP/err")"

# ── 3. "not_run" is not evidence ──────────────────────────────────────────────
mkcontract "refactor-bbbbbbbb.json" ""
run --contract "$R/zuvo/contracts/refactor-bbbbbbbb.json" prove characterization "not_run"; rc=$?
[ "$rc" -eq 2 ] && pass "recording 'not_run' as evidence is rejected" \
  || bad "'not_run' was accepted as proof (exit=$rc)"
run --contract "$R/zuvo/contracts/refactor-bbbbbbbb.json" prove characterization "-"; rc=$?
[ "$rc" -eq 2 ] && pass "a placeholder is rejected too" || bad "'-' accepted as proof (exit=$rc)"

# ── 4. the four spellings the fleet invented map onto the vocabulary ──────────
# READY_FOR_COMMIT (28 in the wild), READY_TO_COMMIT (3), EXECUTION_COMPLETE (8),
# EXECUTION_COMPLETE_UNCOMMITTED (7). Two of those are one state spelled two ways.
mkcontract "refactor-cccccccc.json" "c['prove']['characterization']='PASS'; c['prove']['regression_red']='RED then GREEN'"
for spelling in READY_FOR_COMMIT READY_TO_COMMIT EXECUTION_COMPLETE EXECUTION_COMPLETE_UNCOMMITTED; do
  run --contract "$R/zuvo/contracts/refactor-cccccccc.json" stage "$spelling"; rc=$?
  st=$(python3 -c "import json;print(json.load(open('$R/zuvo/contracts/refactor-cccccccc.json'))['stage'])")
  if [ "$rc" -eq 0 ] && [ "$st" = "PHASE-3.5" ]; then
    pass "$spelling is recorded as PHASE-3.5"
  else
    bad "$spelling became '$st' (exit=$rc)"
  fi
done

run --contract "$R/zuvo/contracts/refactor-cccccccc.json" stage NONSENSE_STAGE; rc=$?
[ "$rc" -eq 2 ] && grep -q 'is not a stage' "$TMP/err" \
  && pass "a stage outside the vocabulary is rejected with the list" \
  || bad "free text was accepted as a stage (exit=$rc)"

# ── 5. sidecars are never resume candidates ──────────────────────────────────
# `refactor-*.json` also matches the adversarial/findings files the skill writes beside a contract.
# In tgm-survey-platform three of those — unparseable as well — were being offered by `continue`.
printf '[]\n' > "$R/zuvo/contracts/refactor-dddddddd-adversarial.json"
printf '{"findings": []}\n' > "$R/zuvo/contracts/refactor-dddddddd-findings.json"
run list
grep -q 'adversarial' "$TMP/out" \
  && bad "a sidecar was listed as a contract" \
  || pass "sidecars are excluded from the listing"

# ── 6. abandoned contracts are not offered ───────────────────────────────────
# A distinct target, so the assertion below cannot match one of the fresh fixtures by accident —
# every other fixture here shares the same `file`, and the first version of this test matched those.
mkcontract "refactor-eeeeeeee.json" "c['stage']='PHASE-2'; c['file']='src/abandoned-target.ts'"
python3 -c "
import os,time
p='$R/zuvo/contracts/refactor-eeeeeeee.json'
old=time.time()-40*86400
os.utime(p,(old,old))"
run list
awk '/RESUMABLE/,/stale/' "$TMP/out" | grep -q 'abandoned-target' \
  && bad "a 40-day-old contract was offered as resumable" \
  || pass "an abandoned contract is counted, not offered"
grep -qE 'stale \(>14d, not offered\): [1-9]' "$TMP/out" \
  && pass "the listing says how many were withheld and why" \
  || bad "stale contracts were hidden without saying so"
run list --json; rc=$?
if [ "$rc" -eq 0 ] && python3 - "$TMP/out" <<'PY2'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
assert data['stale'] == 1, data
assert all(row['file'] != 'src/abandoned-target.ts' for row in data['resumable']), data
PY2
then
  pass "JSON listing counts exactly the one abandoned contract as stale"
else
  bad "JSON stale count or resumable membership is wrong (exit=$rc)"
fi

# Auto-selection must choose the sole active contract, never a terminal one.
AUTO="$TMP/auto-select"
mkdir -p "$AUTO/zuvo/contracts"
git -C "$AUTO" init -q
printf '{"file":"src/live.ts","stage":"PHASE-2","prove":{}}\n' \
  > "$AUTO/zuvo/contracts/refactor-abc123.json"
printf '{"file":"src/parked.ts","stage":"BLOCKED","prove":{}}\n' \
  > "$AUTO/zuvo/contracts/refactor-def456.json"
( cd "$AUTO" && python3 "$BIN" show ) > "$TMP/auto.out" 2> "$TMP/auto.err"; rc=$?
if [ "$rc" -eq 0 ] && grep -Fq 'CONTRACT  src/live.ts' "$TMP/auto.out" &&
   ! grep -Fq 'CONTRACT  src/parked.ts' "$TMP/auto.out"; then
  pass "automatic selection chooses the only active contract"
else
  bad "automatic selection chose a terminal contract or none (exit=$rc): $(head -3 "$TMP/auto.err")"
fi

# ── 7. a malformed contract is reported, not crashed on ──────────────────────
# Nine contracts on disk are a bare LIST at the top level; ten do not parse at all.
printf '[1,2,3]\n' > "$R/zuvo/contracts/refactor-ffffffff.json"
run list; rc=$?
[ "$rc" -eq 0 ] && pass "a malformed contract does not crash the listing" \
  || bad "listing crashed on a malformed contract (exit=$rc): $(head -3 "$TMP/err")"

# ── 8. --force is available, and says what it did ────────────────────────────
mkcontract "refactor-99999999.json" ""
run --contract "$R/zuvo/contracts/refactor-99999999.json" stage COMPLETE --force; rc=$?
[ "$rc" -eq 0 ] && pass "--force records an unproven stage (a human's call)" \
  || bad "--force did not work (exit=$rc)"
grep -q 'forced past' "$TMP/out" \
  && pass "a forced advance says so in the output" \
  || bad "a forced advance is indistinguishable from a proven one"

# ── 9. the characterization command is typed once, and its result is MEASURED ─
# The single most-repeated shell shape in a refactor session is this command: `cd <worktree>` then a
# ~400-character line carrying a database URL, a spec list, a log path and an exit capture,
# recomposed for every round. 66 re-issues of the environment prefix alone across 25 sessions.
# Recording it also turns prove.characterization from a sentence the run typed into a measurement.
mkcontract "refactor-11111111.json" ""
run --contract "$R/zuvo/contracts/refactor-11111111.json" baseline \
  "printf 'Tests  7 passed (7)\n'"; rc=$?
[ "$rc" -eq 0 ] && pass "a passing baseline is recorded and exits 0" \
  || bad "baseline failed on a passing command (exit=$rc): $(head -3 "$TMP/err")"
python3 - "$R/zuvo/contracts/refactor-11111111.json" <<'PY2'
import json, sys
c = json.load(open(sys.argv[1]))
ok = c.get("characterization_cmd") and "7 passed" in c["prove"]["characterization"]
sys.exit(0 if ok else 1)
PY2
[ $? -eq 0 ] && pass "the command AND the parsed count land in the contract" \
  || bad "baseline did not record the command or the count"

# recheck must re-run the STORED command — a fresh one would compare two different things.
run --contract "$R/zuvo/contracts/refactor-11111111.json" recheck; rc=$?
[ "$rc" -eq 0 ] && pass "an unchanged suite rechecks clean" || bad "recheck reported drift (exit=$rc)"
grep -q 'unchanged against the baseline' "$TMP/out"   && pass "the verdict says it compared against the baseline"   || bad "recheck gave no comparison verdict"

# ── 10. a suite that stops doing what it did is DRIFT, and exits non-zero ─────
mkcontract "refactor-22222222.json" ""
run --contract "$R/zuvo/contracts/refactor-22222222.json" baseline "printf 'Tests  7 passed (7)\n'"
python3 - "$R/zuvo/contracts/refactor-22222222.json" <<'PY2'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["characterization_cmd"] = "printf 'Tests  2 failed, 5 passed (7)\n'; exit 1"
json.dump(c, open(p, "w"), indent=1)
PY2
run --contract "$R/zuvo/contracts/refactor-22222222.json" recheck; rc=$?
[ "$rc" -eq 1 ] && pass "a suite that now fails is reported as DRIFT (exit 1)" \
  || bad "drift went unreported (exit=$rc)"
grep -q 'DRIFT' "$TMP/out" && pass "the drift verdict is visible in the block" \
  || bad "no DRIFT marker in the output"

# ── 11. recheck without a baseline refuses rather than inventing one ──────────
mkcontract "refactor-33333333.json" ""
run --contract "$R/zuvo/contracts/refactor-33333333.json" recheck; rc=$?
[ "$rc" -eq 2 ] && grep -q 'no baseline recorded' "$TMP/err" \
  && pass "recheck without a baseline refuses and says why" \
  || bad "recheck invented a comparison with nothing to compare to (exit=$rc)"

# ── 12. an older contract is held to what it was ASKED to prove ──────────────
# The prove block is a v5 concept and the fleet is mostly on v3: of 761 contracts at COMPLETE, 693
# are version 3, and test_quality is absent from the prove block entirely in 717 — not `not_run`,
# simply not a field. Gating on the full v5 set refused 97% of real completed refactors, including
# 94% of the last fortnight's. A gate nobody can pass is not strict, it is broken: everyone reaches
# for --force and it stops meaning anything. After scoping, 92% pass and the 58 that do not are
# contracts that CARRY the field and left it not_run.
python3 - "$R/zuvo/contracts/refactor-44444444.json" <<'PY2'
import json, sys
# A v3 contract: no test_quality, no regression_red — the run was never asked for them.
json.dump({"version": 3, "file": "src/legacy.ts", "type": "SPLIT_FILE", "mode": "full",
           "stage": "PHASE-3.5",
           "prove": {"characterization": "existing:tests/legacy.spec.ts:green:abc1234",
                     "findings_disposition": "2 fixed"}},
          open(sys.argv[1], "w"), indent=1)
PY2
run --contract "$R/zuvo/contracts/refactor-44444444.json" stage COMPLETE; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a v3 contract is not refused for fields its schema never had" \
  || bad "the gate demanded v5 fields from a v3 contract (exit=$rc): $(head -3 "$TMP/err")"

# But a field the contract DOES carry, left unproven, still blocks.
python3 - "$R/zuvo/contracts/refactor-55555555.json" <<'PY2'
import json, sys
json.dump({"version": 3, "file": "src/legacy2.ts", "type": "SPLIT_FILE", "mode": "full",
           "stage": "PHASE-3.5",
           "prove": {"characterization": "existing:tests/x.spec.ts:green:abc1234",
                     "findings_disposition": "2 fixed",
                     "test_quality": "not_run"}},
          open(sys.argv[1], "w"), indent=1)
PY2
run --contract "$R/zuvo/contracts/refactor-55555555.json" stage COMPLETE; rc=$?
[ "$rc" -eq 1 ] && grep -q 'test_quality' "$TMP/err" \
  && pass "a field the contract DOES carry, left not_run, still blocks" \
  || bad "an unproven field the contract tracks was let through (exit=$rc)"

# A v5 contract is held to the full set even when a field is missing outright.
python3 - "$R/zuvo/contracts/refactor-66666666.json" <<'PY2'
import json, sys
json.dump({"version": 5, "file": "src/new.ts", "type": "SPLIT_FILE", "mode": "full",
           "stage": "PHASE-3.5",
           "prove": {"characterization": "existing:tests/y.spec.ts:green:abc1234"}},
          open(sys.argv[1], "w"), indent=1)
PY2
run --contract "$R/zuvo/contracts/refactor-66666666.json" stage COMPLETE; rc=$?
[ "$rc" -eq 1 ] \
  && pass "a v5 contract is held to the full set even for absent fields" \
  || bad "v5 contract skipped the gate on a missing field (exit=$rc)"

# ── 13. v7 prove.mutation — the CLI side of the Phase 3.6 Step 2 gate ────────
# The shell gate (tests/hooks/test-refactor-v4-prove-gate.sh §10) judges the field at push.
# This is the other end: the command that WRITES it. A validator no test exercises is the
# same thing as prose.
mkdir -p "$R/zuvo/audits"; : > "$R/zuvo/audits/mt.json"
mkcontract "refactor-77777777.json" "c['version']=7"
m7="$R/zuvo/contracts/refactor-77777777.json"

run --contract "$m7" prove mutation "clean, looked fine"; rc=$?
[ "$rc" -eq 2 ] && pass "prove mutation: free text is rejected (no verdict, no score, no artifact)"   || bad "free text accepted as a mutation result (exit=$rc)"
run --contract "$m7" prove mutation "PASS:high(native):zuvo/audits/mt.json"; rc=$?
[ "$rc" -eq 2 ] && pass "prove mutation: a score with no digit is rejected"   || bad "a wordy 'score' was accepted (exit=$rc)"
run --contract "$m7" prove mutation "PASS:100%(native):zuvo/audits/never-written.json"; rc=$?
[ "$rc" -eq 2 ] && pass "prove mutation: an artifact that does not exist is rejected"   || bad "a fabricated artifact path was accepted (exit=$rc)"
run --contract "$m7" prove mutation "PASS:100%(native):zuvo/audits/mt.json"; rc=$?
[ "$rc" -eq 0 ] && pass "prove mutation: verdict + numeric score + real artifact is accepted"   || bad "an honest mutation result was rejected (exit=$rc): $(head -3 "$TMP/err")"

# …and it is REQUIRED to leave 3.6 — the boundary AFTER the phase that fills it.
mkcontract "refactor-88888888.json" "c['version']=7; c['prove'].update({'characterization':'PASS','regression_red':'RED then GREEN','findings_disposition':'3 fixed','test_quality':'N/A'})"
run --contract "$R/zuvo/contracts/refactor-88888888.json" stage PHASE-4; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'prove.mutation' "$TMP/err"; then
  pass "v7: PHASE-4 is refused while prove.mutation is unrecorded, and says so"
else
  bad "v7 contract advanced to PHASE-4 without the mutation gate (exit=$rc)"
fi
# The rollout guard: the same contract at v6 knows nothing of the field.
mkcontract "refactor-99999999.json" "c['version']=6; c['prove'].update({'characterization':'PASS','regression_red':'RED then GREEN','findings_disposition':'3 fixed','test_quality':'N/A'})"
run --contract "$R/zuvo/contracts/refactor-99999999.json" stage PHASE-4; rc=$?
if [ "$rc" -eq 1 ] && ! grep -q 'prove.mutation' "$TMP/err" &&
   grep -q 'prove.characterization_after' "$TMP/err"; then
  pass "v6: exempt from prove.mutation, still refused for its own missing proof"
else
  bad "v6 rollout returned exit=$rc without the expected v6-only proof reason: $(head -3 "$TMP/err")"
fi

# ── 13. live-test defects (zuvo:refactor, 2026-11-22) ────────────────────────
# Real git repo: `check` shells into the hook library and needs a consistent contract, so these
# cases build one the way a run does — `init`, a measured baseline/recheck, then the prove fields.
E="$TMP/e2e"
mkdir -p "$E/src" "$E/zuvo/audits"
git -C "$E" init -q
printf 'export const a = 1\n' > "$E/src/a.ts"
printf '# audit\nStatus: PASS\n' > "$E/zuvo/audits/tq.md"
git -C "$E" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$E" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
ec() { ( cd "$E" && ZUVO_AI_RUN=1 python3 "$BIN" --file src/a.ts "$@" ) > "$TMP/out" 2> "$TMP/err"; }

# D9: the contract was hand-written JSON. init writes the v7 schema and keys it by the CLI's hash.
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
KEY=$(python3 -c "import hashlib;print(hashlib.sha256(b'src/a.ts').hexdigest()[:8])")
if [ "$rc" -eq 0 ] && [ -f "$E/zuvo/contracts/refactor-$KEY.json" ] &&
   python3 - "$E/zuvo/contracts/refactor-$KEY.json" <<'PY2'
import json, sys
c = json.load(open(sys.argv[1]))
ok = (c["version"] == 7 and c["kind"] == "refactor-contract" and c["file"] == "src/a.ts"
      and c["scope_fence"] == ["src/a.ts"] and c["behavior_mode"] == "preserve_behavior"
      and c["prove"]["mutation"] == "not_run" and c["stage"] == "PHASE-1")
sys.exit(0 if ok else 1)
PY2
then pass "init writes a v7 contract keyed by SHA-256(path)[:8], found again by --file"
else bad "init did not create the expected contract (exit=$rc): $(head -3 "$TMP/err")"; fi
ec show; rc=$?
[ "$rc" -eq 0 ] && pass "the init'd contract is selected by --file" || bad "--file did not find the init'd contract (exit=$rc)"
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'RESUME' "$TMP/err" \
  && pass "init refuses to overwrite an unfinished contract" \
  || bad "init overwrote a resumable contract (exit=$rc)"
( cd "$E" && python3 "$BIN" init --file /etc/hosts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && pass "init refuses a target outside the repository" || bad "init accepted a path outside the repo (exit=$rc)"
( cd "$E" && python3 "$BIN" init --file src/typo.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && pass "init refuses a file that does not exist (a typo must not mint a contract)" || bad "init accepted a nonexistent file (exit=$rc)"
( cd "$E" && python3 "$BIN" init --file src/a.ts --type split ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && pass "init rejects a non-canonical --type (a mistyped split would skip the effectiveness gate)" || bad "init accepted --type split (exit=$rc)"
ec set behavior_mode '"refactor_and_fix"' >/dev/null; rc=$?
[ "$rc" -eq 1 ] && pass "set cannot switch behavior_mode around init's mode/scope check" || bad "set behavior_mode accepted (exit=$rc)"
( cd "$E" && python3 "$BIN" init --file src/a.ts ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && pass "init needs --type (an empty type silently skips the v5 effectiveness gate)" || bad "init accepted an empty --type (exit=$rc)"

# D9: `prove characterization_probes` is rejected while the skill tells the run to record it.
ec prove characterization_probes "3/3"; rc=$?
[ "$rc" -eq 0 ] && pass "prove accepts characterization_probes" || bad "characterization_probes rejected (exit=$rc)"

# Fill the rest honestly, through the same commands a run uses.
fill() {
  ec baseline "printf 'Tests  3 passed (3)\n'" >/dev/null
  ec recheck >/dev/null
  ec prove blind_audit clean:strict >/dev/null
  ec prove adversarial clean >/dev/null
  ec prove findings_disposition none >/dev/null
  ec prove regression_red "n/a-no-fixes" >/dev/null
  ec prove test_quality "PASS:A:zuvo/audits/tq.md" >/dev/null
  ec prove split_coverage N/A >/dev/null
  ec prove mutation "not_run:no-consent" >/dev/null
}
fill

# D2: no runner and no consent is a DEFINED outcome — check exits 0 and says WARN, never silent.
ec check; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'MUTATION: WARN not_run:no-consent' "$TMP/out"; then
  pass "check accepts not_run:<closed reason> for mutation and reports it as a WARN"
else bad "check did not accept/flag a coded not_run mutation (exit=$rc): $(tail -3 "$TMP/out")"; fi

# D6: COMPLETE is impossible while check is non-zero — via `stage` AND via `set`.
ec set prove.adversarial not_run >/dev/null
ec stage COMPLETE; rc=$?
[ "$rc" -eq 1 ] && grep -q 'requires `check` exit 0' "$TMP/err" \
  && pass "stage COMPLETE is refused while check exits non-zero (no forged COMPLETE)" \
  || bad "COMPLETE accepted over a failing check (exit=$rc)"
ec stage COMPLETE --force; rc=$?
[ "$rc" -eq 1 ] && pass "--force cannot certify COMPLETE over a failing check" || bad "--force certified COMPLETE (exit=$rc)"
ec set stage '"COMPLETE"'; rc=$?
[ "$rc" -eq 1 ] && pass "set cannot write the stage around the gate" || bad "set stage COMPLETE slipped through (exit=$rc)"
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$E/zuvo/contracts/refactor-$KEY.json'))['stage']=='PHASE-1' else 1)" \
  && pass "the refused attempts left the stage untouched" || bad "a refused attempt changed the stage"
ec set prove.adversarial clean >/dev/null

# COMPLETE also needs the move committed: every proof green, HEAD never moved -> refused.
ec stage COMPLETE; rc=$?
[ "$rc" -eq 1 ] && grep -q 'needs the refactor committed' "$TMP/err" \
  && pass "stage COMPLETE is refused when every proof is green but nothing was committed" \
  || bad "COMPLETE accepted with no commit since init (exit=$rc)"
ec set version 6 >/dev/null; rc=$?
[ "$rc" -eq 1 ] && pass "set cannot downgrade the schema version to dodge the v7 check" || bad "set version was accepted (exit=$rc)"

# An unrelated commit moves HEAD while the target stays dirty: still not committed.
printf 'export const a = 2\n' > "$E/src/a.ts"; printf 'x\n' > "$E/src/other.ts"
git -C "$E" add src/other.ts; git -C "$E" -c user.email=t@t -c user.name=t commit -qm unrelated >/dev/null 2>&1
fill
ec stage COMPLETE; rc=$?
[ "$rc" -eq 1 ] && grep -q 'uncommitted changes in the scope fence' "$TMP/err" \
  && pass "an unrelated commit does not make an uncommitted refactor COMPLETE" \
  || bad "COMPLETE accepted with the target still dirty (exit=$rc)"
git -C "$E" checkout -q -- src/a.ts 2>/dev/null

# The positive path: a proven, committed run reaches COMPLETE, and the next init archives it.
printf 'export const a = 2\n' > "$E/src/a.ts"
git -C "$E" -c user.email=t@t -c user.name=t commit -qam second >/dev/null 2>&1
fill
ec stage COMPLETE; rc=$?
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$E/zuvo/contracts/refactor-$KEY.json'))['stage']=='COMPLETE' else 1)" \
  && [ "$rc" -eq 0 ] && pass "stage COMPLETE is accepted when check exits 0 and HEAD moved" || bad "a valid run could not reach COMPLETE (exit=$rc): $(head -3 "$TMP/err")"
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
H2=$(git -C "$E" rev-parse --short=7 HEAD)
[ "$rc" -eq 0 ] && [ -f "$E/zuvo/contracts/archive/refactor-$KEY-$H2.json" ] && [ ! -f "$E/zuvo/contracts/refactor-$KEY-$H2.json" ] \
  && pass "init archives a COMPLETE contract and starts a fresh one" \
  || bad "init did not archive the COMPLETE contract (exit=$rc): $(head -3 "$TMP/err")"
printf 'export const a = 3\n' > "$E/src/a.ts"; git -C "$E" -c user.email=t@t -c user.name=t commit -qam third >/dev/null 2>&1
fill
ec stage COMPLETE >/dev/null
printf 'export const a = 4\n' > "$E/src/a.ts"; git -C "$E" -c user.email=t@t -c user.name=t commit -qam fourth >/dev/null 2>&1
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && [ "$(ls "$E/zuvo/contracts/archive/" | grep -c "^refactor-$KEY-.*\.json$")" -eq 2 ] \
  && pass "successive archives are kept side by side" || bad "the earlier archive was lost (exit=$rc)"
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS --behavior-scope foo ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 2 ] && pass "init refuses a behavior scope without refactor_and_fix" || bad "scope without mode accepted (exit=$rc)"
( cd "$E/src" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q RESUME "$TMP/err" && pass "a repo-relative --file resolves from a subdirectory" || bad "subdirectory init missed the target (exit=$rc)"
fill

# D3: .git not writable -> the run records commit_execution and ends in EXECUTION_COMPLETE.
ec set commit_execution '"blocked:index.lock not writable"' >/dev/null
ec check; rc=$?
[ "$rc" -eq 0 ] && grep -q 'COMMIT: none (commit_execution=blocked:' "$TMP/out" \
  && pass "check passes in no-commit mode and states that nothing was committed" \
  || bad "check lost the no-commit disclosure (exit=$rc)"
ec stage COMPLETE; rc=$?
[ "$rc" -eq 1 ] && grep -q 'EXECUTION_COMPLETE' "$TMP/err" \
  && pass "an uncommitted run cannot be marked COMPLETE" \
  || bad "COMPLETE accepted although nothing was committed (exit=$rc)"
ec stage EXECUTION_COMPLETE; rc=$?
[ "$rc" -eq 0 ] && pass "EXECUTION_COMPLETE is the accepted end state of a no-commit run" \
  || bad "EXECUTION_COMPLETE refused for a no-commit run (exit=$rc): $(head -3 "$TMP/err")"
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'nothing has been committed' "$TMP/err" \
  && pass "an uncommitted finished run is not silently overwritten" || bad "init over an uncommitted run (exit=$rc)"
printf 'export const a = 5\n' > "$E/src/a.ts"; git -C "$E" -c user.email=t@t -c user.name=t commit -qam fifth >/dev/null 2>&1
( cd "$E" && python3 "$BIN" init --file src/a.ts --type EXTRACT_METHODS ) > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "once the owner committed the uncommitted run, the next run on the target can start" \
  || bad "a finished uncommitted run blocks the next one (exit=$rc): $(head -3 "$TMP/err")"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
