#!/usr/bin/env bash
# RED/meta-test for run.sh — proves the scorer catches both a false-negative
# (vulnerable fixture missing its expected finding) and a false-positive
# (clean twin carrying the finding), and passes a correct pair.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/run.sh"
fail() { echo "META-FAIL: $1" >&2; exit 1; }

[ -x "$RUN" ] || fail "run.sh missing or not executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
man="$tmp/manifest.json"
fdir="$tmp/findings"
mkdir -p "$fdir"
cat > "$man" <<'JSON'
{ "classes": [ { "class": "demo", "finding_type": "demo_vuln",
  "vulnerable_path": "demo/vulnerable", "clean_path": "demo/clean", "stack": "generic" } ] }
JSON

# Case A — correct pair → scorer exits 0
printf '{"findings":[{"type":"demo_vuln"}]}' > "$fdir/demo-vulnerable.json"
printf '{"findings":[]}'                     > "$fdir/demo-clean.json"
"$RUN" --manifest "$man" --findings "$fdir" >/dev/null 2>&1 || fail "correct pair should PASS"

# Case B — false negative (vulnerable missing finding) → scorer exits nonzero
printf '{"findings":[]}' > "$fdir/demo-vulnerable.json"
printf '{"findings":[]}' > "$fdir/demo-clean.json"
"$RUN" --manifest "$man" --findings "$fdir" >/dev/null 2>&1 && fail "false-negative should FAIL"

# Case C — false positive (clean carries finding) → scorer exits nonzero
printf '{"findings":[{"type":"demo_vuln"}]}' > "$fdir/demo-vulnerable.json"
printf '{"findings":[{"type":"demo_vuln"}]}' > "$fdir/demo-clean.json"
"$RUN" --manifest "$man" --findings "$fdir" >/dev/null 2>&1 && fail "false-positive should FAIL"

# Case D — invalid-JSON clean twin must FAIL, not score as "clean" (adversarial CRITICAL)
printf '{"findings":[{"type":"demo_vuln"}]}' > "$fdir/demo-vulnerable.json"
printf 'broken{not json'                      > "$fdir/demo-clean.json"
"$RUN" --manifest "$man" --findings "$fdir" >/dev/null 2>&1 && fail "invalid-JSON clean twin should FAIL"

# Case E — --classes matching zero classes must FAIL, not green (adversarial CRITICAL)
printf '{"findings":[{"type":"demo_vuln"}]}' > "$fdir/demo-vulnerable.json"
printf '{"findings":[]}'                     > "$fdir/demo-clean.json"
"$RUN" --manifest "$man" --findings "$fdir" --classes nonexistent_typo >/dev/null 2>&1 && fail "zero-class filter should FAIL"

# Case F — malformed manifest must FAIL loudly, not exit 0 (adversarial CRITICAL)
printf 'not a json manifest{' > "$tmp/bad-manifest.json"
"$RUN" --manifest "$tmp/bad-manifest.json" --findings "$fdir" >/dev/null 2>&1 && fail "malformed manifest should FAIL"

# Case G — alternate key spelling .finding_type is honored
printf '{"findings":[{"finding_type":"demo_vuln"}]}' > "$fdir/demo-vulnerable.json"
printf '{"findings":[]}'                              > "$fdir/demo-clean.json"
"$RUN" --manifest "$man" --findings "$fdir" >/dev/null 2>&1 || fail ".finding_type key should be honored"

echo "META-PASS: scorer catches FN + FP + bad-JSON + zero-class + bad-manifest, honors both keys"
