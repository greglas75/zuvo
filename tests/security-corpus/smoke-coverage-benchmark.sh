#!/usr/bin/env bash
# Whole-feature smoke benchmark (SMOKE1 / AC-S1 / AC-S2) for security-detection-coverage.
#
# End-to-end: scores the FULL corpus (what zuvo:security-audit + zuvo:pentest --from-audit
# detect, with IC-3 reconciliation already applied in the _findings dumps) against the
# planted-vuln manifest. The LLM skill-runs produce the per-fixture findings.json (in
# --findings); this runner is the deterministic gate over them.
#
# Asserts:
#   - every planted vuln in the manifest is detected (vulnerable twin) and no clean twin
#     false-positives  (delegated to run.sh, strict provenance)
#   - each planted vuln appears exactly ONCE (reconciliation idempotent — no per-class dup)
#   - >= MIN_NEW_CLASSES distinct NET-NEW vuln classes detected (AC-S1)
#   - zero regressions vs the recorded baseline class set (AC-S1)
#   - false-positive count does not increase vs baseline (AC-S2)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINDINGS="${1:-$HERE/_findings}"
MANIFEST="$HERE/manifest.json"
MIN_NEW_CLASSES="${MIN_NEW_CLASSES:-10}"
BASELINE="$HERE/baseline-classes.txt"   # classes detected BEFORE this feature (empty = greenfield)
fail() { echo "SMOKE-FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq required"

# 1) full-corpus detection + no-FP, strict provenance (reuses the proven scorer)
echo "== full-corpus detection (run.sh, strict provenance) =="
bash "$HERE/run.sh" --findings "$FINDINGS" --require-provenance || fail "corpus not fully detected / clean-twin FP / provenance"

# 2) reconciliation idempotence: each class's vulnerable findings carry its type exactly once
echo "== reconciliation idempotence (one finding per planted vuln) =="
while IFS=$'\t' read -r cls ft; do
  [ -n "$cls" ] || continue
  f="$FINDINGS/$cls-vulnerable.json"
  [ -f "$f" ] || continue
  cnt=$(jq --arg t "$ft" '[.findings[]? | select(.type==$t or .finding_type==$t)] | length' "$f")
  [ "$cnt" = 1 ] || fail "$cls: expected exactly 1 '$ft' finding (reconciled), got $cnt"
done < <(jq -r '.classes[] | [.class, .finding_type] | @tsv' "$MANIFEST")

# 3) net-new distinct vuln classes (AC-S1)
# Derive DETECTED from the actual findings dumps — a finding_type counts only if a
# vulnerable dump really emitted it (not merely because the manifest lists the class).
DETECTED=$(while IFS=$'\t' read -r cls ft; do
  [ -n "$cls" ] || continue
  f="$FINDINGS/$cls-vulnerable.json"
  [ -f "$f" ] && jq -e --arg t "$ft" 'any(.findings[]?; .type==$t or .finding_type==$t)' "$f" >/dev/null 2>&1 && echo "$ft"
done < <(jq -r '.classes[] | [.class, .finding_type] | @tsv' "$MANIFEST") | sort -u)
NEW_COUNT=$(printf '%s\n' "$DETECTED" | grep -vxF -f "$BASELINE" 2>/dev/null | grep -c . || true)
echo "== net-new vuln classes: $NEW_COUNT (threshold $MIN_NEW_CLASSES) =="
[ "$NEW_COUNT" -ge "$MIN_NEW_CLASSES" ] || fail "only $NEW_COUNT net-new classes (< $MIN_NEW_CLASSES)"

# 4) zero regressions: every baseline class still present in the detected set (AC-S1)
if [ -s "$BASELINE" ]; then
  while read -r b; do
    [ -n "$b" ] || continue
    printf '%s\n' "$DETECTED" | grep -qxF "$b" || fail "REGRESSION: baseline class '$b' no longer detected"
  done < "$BASELINE"
fi

# 5) FP non-increasing (AC-S2): clean twins produced zero findings of their class (run.sh already
#    enforced no class-FP; assert the clean dumps have no findings at all to bound total FP)
FP=0
for c in "$FINDINGS"/*-clean.json; do
  [ -f "$c" ] || continue
  n=$(jq '[.findings[]?] | length' "$c"); FP=$((FP + n))
done
BASE_FP=$(cat "$HERE/baseline-fp-count.txt" 2>/dev/null || echo 0)
echo "== false positives: $FP (baseline $BASE_FP) =="
[ "$FP" -le "$BASE_FP" ] || fail "FP rate increased: $FP > $BASE_FP"

echo "SMOKE-PASS: full corpus detected + reconciled, $NEW_COUNT net-new classes, 0 regressions, FP $FP<=$BASE_FP"
