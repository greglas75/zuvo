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


echo "=== identity validation on --mark ==="
# The failure this prevents: recording a disposition against the heading you EDITED instead of the
# proposal you dispositioned. It writes cleanly, marks nothing, and nobody notices.
python3 "$DP" --mark applied --file skills/refactor/SKILL.md --section "Totally Made Up Section" >/dev/null 2>&1 \
  && bad "--mark accepted an identity that matches no proposal" \
  || ok "--mark rejects an identity that matches no proposal"
python3 "$DP" --mark applied --file skills/refactor/SKILL.md --section "Totally Made Up Section" 2>&1 \
  | grep -qi 'sections known for\|did you mean' && ok "rejection suggests the real section names" \
  || bad "rejection gives no hint about the correct identity"
python3 "$DP" --mark applied --file skills/refactor/SKILL.md --section "Made Up" --force >/dev/null 2>&1 \
  && ok "--force still allows a deliberate pre-mark" || bad "--force escape does not work"
# an orphan already in the ledger must be REPORTED, never silent
python3 "$DP" 2>&1 | grep -qi 'match no proposal' && ok "existing orphans are reported, not silent" \
  || bad "orphaned ledger rows are invisible"

echo "=== overlapping mining windows must NOT inflate the count ==="
# The 2026-07-30 failure: retro-mine windows overlap (07-29 covered 07-22..29, 07-30 covered
# 07-23..30), so ONE retro lands in several digests. Counting digest occurrences turned 9 genuinely
# new retros into 111 "recurring" proposals — every ×1 in the overlap crossed the apply bar. The
# count must key on the source retro (its header line), not on how many digests mention it.
rm -f "$TMP/mining"/*.md "$TMP/mining/proposals-ledger.tsv"
for d in 2026-08-01 2026-08-02; do
  cat > "$TMP/mining/digest-$d.md" <<'D'
## Change proposals
### P3 [mac] ## 2026-07-31T10:00:00Z refactor demo one and the same run
FILE: skills/refactor/SKILL.md | SECTION: Overlap Section
CONTENT:
```
identical proposal, mined twice from ONE retro
```
RATIONALE: window overlap.
D
done
out=$(python3 "$DP" --all 2>&1)
echo "$out" | grep -q '×1  skills/refactor/SKILL.md  ::  Overlap Section'   && ok "one retro in two overlapping digests counts ×1"   || bad "overlap inflated the count: $(echo "$out" | grep -o '×[0-9]*  skills/refactor/SKILL.md  ::  Overlap Section')"
echo "$out" | grep -q '\[APPLY\].*Overlap Section'   && bad "phantom recurrence crossed the apply bar"   || ok "phantom recurrence stays below the apply bar"

echo "=== …but two DIFFERENT retros still count as a real recurrence ==="
cat > "$TMP/mining/digest-2026-08-03.md" <<'D'
## Change proposals
### P3 [mac] ## 2026-08-02T11:00:00Z refactor demo a genuinely different run
FILE: skills/refactor/SKILL.md | SECTION: Overlap Section
CONTENT:
```
same section, different retro
```
RATIONALE: real recurrence.
D
out=$(python3 "$DP" --all 2>&1)
echo "$out" | grep -q '×2  skills/refactor/SKILL.md  ::  Overlap Section'   && ok "two distinct retros count ×2 (dedup does not under-count)"   || bad "real recurrence was collapsed: $(echo "$out" | grep -o '×[0-9]*  skills/refactor/SKILL.md  ::  Overlap Section')"

echo "=== header dialects: same retro written three ways ==="
# Date-only, full-ISO and bracketed-tag headers are the SAME run reported by different miners;
# a date regex splits them apart, the normalized header line does not.
rm -f "$TMP/mining"/*.md
i=0
for h in '## 2026-08-05T09:00:00Z review demo shared title'          '## 2026-08-05T09:00:00Z review demo shared title'          '[DEGRADED-CONTEXT] ## 2026-08-05T09:00:00Z review demo shared title'; do
  i=$((i+1))
  { printf '## Change proposals
### P3 [mac] %s
' "$h"
    printf 'FILE: skills/review/SKILL.md | SECTION: Dialect Section
CONTENT:
```
x
```
RATIONALE: y.
'
  } > "$TMP/mining/digest-2026-09-0$i.md"
done
out=$(python3 "$DP" --all 2>&1)
echo "$out" | grep -q '×1  skills/review/SKILL.md  ::  Dialect Section'   && ok "host-tag dialect does not split one retro into several"   || bad "dialects split one retro: $(echo "$out" | grep -o '×[0-9]*  skills/review/SKILL.md  ::  Dialect Section')"

echo "=== a shifted heading must not collapse distinct retros to one ==="
# Raised by the adversarial pass on this very change (3 providers, CRITICAL). It does NOT reproduce
# on today's format — verified: every live block's line 0 is the heading remainder. But if an
# emitter ever moves the heading to its own line, line 0 becomes the `FILE:` line, which is
# IDENTICAL for the same proposal across DIFFERENT retros — so every recurrence would collapse to
# 1 and the apply bar would sit permanently empty while looking clean. Over-counting is the safe
# direction; this locks it.
rm -f "$TMP/mining"/*.md "$TMP/mining/proposals-ledger.tsv"
# The shape that actually reaches the guard is FILE: on the SAME line as `### P<n>` — the two
# other shifted layouts (heading on its own line, heading absent) leave line 0 empty and hit the
# length fallback instead. Verified by tracing all three through the BLOCK regex; a fixture using
# the wrong shape would pass with or without the guard, i.e. prove nothing.
i=0
for when in '2026-10-01' '2026-10-02'; do
  i=$((i+1))
  { printf '## Change proposals\n### P3 FILE: skills/review/SKILL.md | SECTION: Shifted Heading\n'
    printf 'CONTENT:\n```\nrun %s on %s\n```\nRATIONALE: y.\n' "$i" "$when"
  } > "$TMP/mining/digest-2026-11-0$i.md"
done
out=$(python3 "$DP" --all 2>&1)
if echo "$out" | grep -q '×2  skills/review/SKILL.md  ::  Shifted Heading'; then
  ok "two distinct retros still count ×2 when the heading is on its own line"
else
  bad "shifted heading collapsed distinct retros: $(echo "$out" | grep -o '×[0-9]*  skills/review/SKILL.md  ::  Shifted Heading')"
fi

echo "=== section identity: spelling must not fork a proposal ==="
# The SECTION field is free text an LLM writes per retro, so one place arrives spelled many ways.
# Keying on the raw string forked them: measured on the live digests 2026-09-17, 187 twin groups
# carried 225 redundant rows, 80 groups sat as several x1 "consider" items that would clear the
# x2 bar if counted together, and 105 above-bar items stayed OPEN although a twin spelling was
# already marked applied. Four spellings of ONE section here — case, comma, em-dash, and a
# trailing parenthetical qualifier — must aggregate to a single x4.
rm -f "$TMP/mining"/*.md
i=0
for sec in 'Phase 3.2b native runner execution' 'Phase 3.2b Native runner execution' 'Phase 3.2b — Native runner execution' 'Phase 3.2b native runner execution (fresh process)'; do
  i=$((i+1))
  { printf '## Change proposals\n### P4 [mac] ## [2026-12-0%s] [mutation-test] [proj%s]\n' "$i" "$i"
    printf 'FILE: skills/mutation-test/SKILL.md | SECTION: %s\n' "$sec"
    printf 'CONTENT:\n```\nre-run survivors in a fresh process\n```\nRATIONALE: false survivors.\n'
  } > "$TMP/mining/digest-2026-12-0$i.md"
done
json=$(python3 "$DP" --json --all 2>/dev/null)
echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mt=[p for p in d if p['file']=='skills/mutation-test/SKILL.md']
assert len(mt)==1, f'four spellings forked into {len(mt)} proposals'
assert mt[0]['count']==4, f\"count is {mt[0]['count']}, expected 4\"
assert len(mt[0]['variants'])==4, 'variants must record every spelling seen'
print('OK')" >/dev/null 2>&1 && ok "four spellings of one section aggregate to a single ×4" || bad "section spellings still fork the proposal"

# A disposition written under ONE spelling must close the proposal whatever spelling the next
# digest uses — that is the half that left 105 finished items looking open.
printf '# DATE\tFILE\tSECTION\tDISPOSITION\tREF\tNOTE\n' > "$TMP/mining/proposals-ledger.tsv"
printf '2026-12-09T00:00:00Z\tskills/mutation-test/SKILL.md\tPhase 3.2b, Native Runner Execution (fresh process)\tapplied\tv1.6.77\tclosed under another spelling\n' >> "$TMP/mining/proposals-ledger.tsv"
out=$(python3 "$DP" 2>&1)
if echo "$out" | grep -q 'Phase 3.2b'; then
  bad "a disposition under a different spelling did not close the proposal"
else
  ok "disposition closes the proposal across spellings"
fi
echo "$out" | grep -q 'match no proposal' && bad "ledger row wrongly reported as an orphan" || ok "cross-spelling ledger row is not an orphan"
rm -f "$TMP/mining/proposals-ledger.tsv"

echo "=== unresolvable target: bucket, but FAIL OPEN when the repo is not visible ==="
# Proposals naming a file that does not exist in the checkout (another repo, an installed helper,
# a deleted file) are reported separately instead of padding the open count. But "cannot see the
# repo" is not "the target is missing": with ZUVO_REPO pointing nowhere, every proposal fell into
# that bucket and the report printed an empty open list — a clean bill of health produced by not
# looking. Caught on the test farm, where ~/DEV/zuvo-plugin does not exist.
rm -f "$TMP/mining"/*.md
{ printf '## Change proposals\n### P3 [mac] ## [2026-12-20] [ship] [p]\n'
  printf 'FILE: skills/ship/SKILL.md | SECTION: Phase 4\n'
  printf 'CONTENT:\n```\nreal target\n```\nRATIONALE: r.\n'
  printf '### P3 [mac] ## [2026-12-21] [ship] [p]\n'
  printf 'FILE: ~/DEV/some-other-repo/thing.md | SECTION: Elsewhere\n'
  printf 'CONTENT:\n```\nforeign target\n```\nRATIONALE: r.\n'
} > "$TMP/mining/digest-2026-12-20.md"

fake_repo="$TMP/fakerepo"; mkdir -p "$fake_repo/skills/ship"
printf '# ship\n' > "$fake_repo/skills/ship/SKILL.md"
out=$(ZUVO_REPO="$fake_repo" python3 "$DP" --all 2>&1)
echo "$out" | grep -q 'whose target does not exist' && ok "foreign target is bucketed, not counted as open" || bad "unresolvable target was not bucketed"
echo "$out" | grep -q 'skills/ship/SKILL.md' && ok "resolvable target still reported" || bad "resolvable target vanished"

out=$(ZUVO_REPO="$TMP/definitely-not-a-checkout" python3 "$DP" --all 2>&1)
echo "$out" | grep -q 'whose target does not exist' && bad "invisible repo treated every target as missing (silent empty report)" || ok "invisible repo fails OPEN — nothing is bucketed on ignorance"
echo "$out" | grep -q 'skills/ship/SKILL.md' && ok "proposals still listed when the repo is not visible" || bad "report went empty when the repo is not visible"

echo "=== empty state ==="
rm -f "$TMP/mining"/*.md
python3 "$DP" 2>&1 | grep -qi 'no change proposals' && ok "no digests -> clean message, no crash" || bad "empty state crashed"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
