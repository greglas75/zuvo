#!/usr/bin/env bash
# Tests scripts/zuvo-home/digest-proposals — surfaces + dedups + ranks retro-mine change proposals.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DP="$ROOT/scripts/zuvo-home/digest-proposals"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_DIR="$TMP"; mkdir -p "$TMP/mining"

mk(){ cat > "$TMP/mining/digest-$1.md"; }
# two digests; a proposal that recurs across both (should aggregate to count 2 -> apply bar),
# one one-off (below bar), one P0 (qualifies despite single), and a Codex-built path (normalizes).
mk 2026-07-20 <<'D'
## Change proposals
### P3 [mac] ## [2026-07-20] [refactor] [X]
FILE: skills/refactor/SKILL.md | SECTION: Adversarial Review
CONTENT:
```
Persist finding fingerprints between passes.
```
RATIONALE: wasted passes re-litigating findings.
### P5 [mac] one-off
FILE: skills/build/SKILL.md | SECTION: Phase 4.4
CONTENT:
```
some one-off idea
```
RATIONALE: happened once.
D
mk 2026-07-21 <<'D'
## Change proposals
### P4 [mac] ## [2026-07-21] [refactor] [Y]
FILE: ~/.codex/skills/refactor/SKILL.md | SECTION: Adversarial Review
CONTENT:
```
Persist finding fingerprints between passes (variant).
```
RATIONALE: same recurring waste.
### P0 [mac] critical
FILE: skills/review/SKILL.md | SECTION: 1.6 Adversarial
CONTENT:
```
verify base is ancestor before diff
```
RATIONALE: false CRITICALs.
D

echo "=== dedup + normalize + apply-bar ==="
out=$(python3 "$DP" 2>&1)
echo "$out" | grep -q 'skills/refactor/SKILL.md  ::  Adversarial Review' && ok "recurring proposal surfaced on the SOURCE path" || bad "recurring proposal missing/wrong path"
echo "$out" | grep -qi 'codex' && bad "Codex-built path leaked (not normalized)" || ok "Codex path normalized to source"
# recurring (×2) is APPLY, one-off (×1 P5) is not
python3 "$DP" --json 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin)
ref=[p for p in d if p['file']=='skills/refactor/SKILL.md' and 'Adversarial' in p['section']]
assert ref and ref[0]['count']==2, 'refactor proposal should aggregate to count 2'
assert ref[0]['qualifies'], 'count-2 should qualify'
print('OK')" >/dev/null 2>&1 && ok "recurring aggregates to count 2 and qualifies" || bad "recurrence aggregation wrong"
python3 "$DP" --json 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin)
p0=[p for p in d if p['file']=='skills/review/SKILL.md']
assert p0 and p0[0]['best_prio']==0 and p0[0]['qualifies'], 'P0 should qualify at count 1'
print('OK')" >/dev/null 2>&1 && ok "P0 qualifies even as a single occurrence" || bad "P0 not qualifying"
python3 "$DP" 2>&1 | grep -q 'skills/build/SKILL.md' && bad "one-off (P5 ×1) wrongly in apply set" || ok "one-off below bar (not in apply set)"
python3 "$DP" --all 2>&1 | grep -q 'skills/build/SKILL.md' && ok "one-off visible under --all" || bad "one-off missing from --all"


echo "=== disposition ledger ==="
# marking a proposal hides it from the default (open-only) view but keeps it under --show-done
python3 "$DP" --mark applied --file skills/refactor/SKILL.md --section "Adversarial Review" --ref v9.9.9 >/dev/null 2>&1 \
  && ok "--mark applied writes a row" || bad "--mark failed"
python3 "$DP" 2>&1 | grep -q 'Adversarial Review' && bad "dispositioned proposal still shown by default" || ok "dispositioned hidden from default view"
python3 "$DP" --show-done 2>&1 | grep -q 'APPLIED v9.9.9' && ok "--show-done shows it with disposition + ref" || bad "--show-done lost the disposition"
python3 "$DP" 2>&1 | grep -q '1 dispositioned' && ok "header counts dispositioned vs open" || bad "header count wrong"
# latest row wins (append-only, re-mark flips it)
python3 "$DP" --mark rejected --file skills/refactor/SKILL.md --section "Adversarial Review" --note "changed mind" >/dev/null 2>&1
python3 "$DP" --show-done 2>&1 | grep -q 'REJECTED' && ok "latest row wins on re-mark" || bad "re-mark did not override"
# validation: bad disposition and missing args are rejected, not silently written
python3 "$DP" --mark bogus --file a --section b >/dev/null 2>&1 && bad "invalid disposition accepted" || ok "invalid disposition rejected"
python3 "$DP" --mark applied --file a >/dev/null 2>&1 && bad "missing --section accepted" || ok "missing --section rejected"
# a corrupt ledger must not break reporting
printf 'garbage line without tabs\n' >> "$TMP/mining/proposals-ledger.tsv"
python3 "$DP" >/dev/null 2>&1 && ok "corrupt ledger line tolerated (report still runs)" || bad "corrupt ledger broke the report"
rm -f "$TMP/mining/proposals-ledger.tsv"

echo "=== empty state ==="
rm -f "$TMP/mining"/*.md
python3 "$DP" 2>&1 | grep -qi 'no change proposals' && ok "no digests -> clean message, no crash" || bad "empty state crashed"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
