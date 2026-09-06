#!/usr/bin/env bash
# Counts must represent finding records, and agree between artifacts and provider telemetry.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
printf 'const reviewed = true;\n' > "$TMP/input.js"
cat > "$TMP/bin/mock-counts" <<'SH'
#!/bin/sh
cat >/dev/null
cat "$ZUVO_COUNT_FIXTURE"
SH
chmod +x "$TMP/bin/mock-counts"
fails=0
run_case() {
  local name="$1" counts="$2"; shift 2
  local expected_status="${COUNT_EXPECT_STATUS:-complete}"
  local artifact="$TMP/$name.md" log="$TMP/$name.tsv"
  : > "$log"
  if ! env PATH="$TMP/bin:$PATH" ZUVO_HOME="$TMP/home" ZUVO_COUNT_FIXTURE="$TMP/fixture" \
    ZUVO_RUN_ID="counts-$name" ZUVO_ADVERSARIAL_LOG_FILE="$log" \
    ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-counts \
    bash "$ROOT/scripts/adversarial-review.sh" --single --files "$TMP/input.js" --artifact "$artifact" "$@" \
    < /dev/null > "$TMP/output" 2>&1; then
    echo "FAIL: $name runner"; cat "$TMP/output"; fails=$((fails+1)); return
  fi
  local actual logged total
  total=$(awk -v c="$counts" 'BEGIN {split(c,a," "); print a[1]+a[2]+a[3]}')
  actual=$(sed -n '1,/^---$/p' "$artifact" | awk -F= '/^(critical|warning|info)=/ {printf "%s ",$2}')
  logged=$(awk -F '\t' '$14=="mock-counts" {print $8,$9,$10}' "$log")
  if [ "$actual" = "$counts " ] && [ "$logged" = "$counts" ] \
    && grep -qx "count_status=$expected_status" "$artifact" \
    && grep -qx "total_findings=$total" "$artifact"; then
    echo "PASS: $name artifact and telemetry = $counts"
  else
    echo "FAIL: $name expected [$counts], artifact [$actual], telemetry [$logged]"
    fails=$((fails+1))
  fi
  if [ "$expected_status" = partial ] && ! grep -q 'counts are incomplete' "$TMP/output"; then
    echo "FAIL: $name incomplete counts were not reported"
    fails=$((fails+1))
  fi
}
printf 'No CRITICAL issues found. No WARNING or INFO findings.\nNO ISSUES FOUND.\n' > "$TMP/fixture"
run_case clean '0 0 0'
cat > "$TMP/fixture" <<'TEXT'
SEVERITY: CRITICAL
ISSUE: CRITICAL failure is described here again.
- **SEVERITY:** WARNING
ISSUE: The WARNING summary repeats CRITICAL.
1. **SEVERITY: INFO** — additional explanation
ISSUE: Extra INFO in the explanation does not create a finding.
No other CRITICAL issues found.
TEXT
run_case records '1 1 1'
printf 'CRITICAL: legacy finding\nWARNING: legacy finding\nINFO: legacy finding\n' > "$TMP/fixture"
COUNT_EXPECT_STATUS=partial run_case legacy '1 1 1'
printf '%s\n' '{"findings":[{"severity":"CRITICAL","issue":"WARNING INFO CRITICAL"},{"severity":"CRITICAL"},{"severity":"WARNING"}],"summary":"CRITICAL WARNING INFO"}' > "$TMP/fixture"
run_case json '2 1 0' --json
printf '  ```JSON\n{"findings":[{"severity":"INFO"}]}\n  ```\n' > "$TMP/fixture"
run_case fenced '0 0 1' --json
printf '{"findings":[],"summary":"No CRITICAL, WARNING or INFO issues"}\n' > "$TMP/fixture"
run_case empty_json '0 0 0' --json
printf '%s\n' '{"findings":[{"severity":"CRITICAL"},{"severity":null},{"issue":"missing severity"},{"severity":17},false,{"severity":"warning"}]}' > "$TMP/fixture"
COUNT_EXPECT_STATUS=partial run_case mixed_json '1 1 0' --json
printf '{"findings":[{"severity":"CRITICAL"}\n' > "$TMP/fixture"
COUNT_EXPECT_STATUS=partial run_case malformed_json '0 0 0' --json
printf '## SEVERITY: WARNING\n' > "$TMP/fixture"
run_case heading '0 1 0'
printf 'Here is the review:\n```json\n{"findings":[{"severity":"CRITICAL"}]}\n```\nEnd of review.\n' > "$TMP/fixture"
run_case wrapped_json '1 0 0' --json
printf 'CRITICAL: None\nWARNING: 0\nINFO: No issues\n' > "$TMP/fixture"
run_case negative_summary '0 0 0'
printf '### 1. SEVERITY: CRITICAL\nSEVERITY: WARNING\n' > "$TMP/fixture"
run_case compound_heading '1 1 0'
printf 'SEVERITY: CRITICAL\nSeverity - WARNING\n' > "$TMP/fixture"
COUNT_EXPECT_STATUS=partial run_case mixed_format '1 0 0'
printf 'CRITICAL: title\nSEVERITY: CRITICAL\nWARNING: operational note\n' > "$TMP/fixture"
COUNT_EXPECT_STATUS=partial run_case duplicate_title '1 0 0'
for envelope in '{}' '[]' '{"error":"service unavailable"}'; do
  printf '%s\n' "$envelope" > "$TMP/fixture"
  COUNT_EXPECT_STATUS=partial run_case unexpected_schema '0 0 0' --json
 done
[ "$fails" -eq 0 ] || { echo "SOME FAILED: $fails"; exit 1; }
echo 'ALL PASS'
