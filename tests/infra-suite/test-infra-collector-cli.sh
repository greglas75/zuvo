#!/usr/bin/env bash
# Task 4 — infra-collect.sh CLI skeleton contract test.
# TDD: written RED first (no scripts/infra-collect.sh), then collector authored GREEN.
#
# NO Docker, NO SSH, NO network. Pure CLI + dry-run + static-grep assertions.
#
# Assertions:
#   1. missing --host                       → exit 1 + usage on stderr
#   2. malformed --host (`nouser`, `user@`) → exit 1
#   3. --out into unwritable parent          → exit 1 BEFORE any connection
#   4. static grep: `command -v jq` hard gate present in script
#   5. --dry-run --no-install                → exit 0; prints WOULD-run commands;
#        <2s wall; printed list (minus /tmp/zuvo- lines) greps ZERO mutating patterns;
#        consent-install block ABSENT under --no-install
#   6. every printed `ssh` line contains the FULL IC-8 flag string (StrictHostKeyChecking=yes)
#   7. every printed `find` line contains `-xdev`
#   8. static greps: SSH_OPTS defined ONCE (flag-string literal count == 1);
#        named constants CHECK_TIMEOUT_S / TRIVY_TIMEOUT_S / CONNECT_TIMEOUT_S /
#        WALL_CLOCK_LIMIT_S; SED_REDACT constant
#   9. dry-run writes bundle SKELETON to --out: jq-valid; required keys present;
#        tool_availability includes grype; every checks[].id matches ^IS([1-9]|1[0-2])-;
#        external.vantage ∈ proxy|direct|none|failed (skeleton: none)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
COLLECTOR="$ROOT_DIR/scripts/infra-collect.sh"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required for this test"; exit 1; }

# ---------------------------------------------------------------------------
# Temp-file registry + cleanup trap (all temp files cleaned on EXIT)
# ---------------------------------------------------------------------------
ERR_FILE=""
DRY_OUT=""
OUT_JSON=""
BRANCH_OUT=""

_cleanup() {
  rm -f "$ERR_FILE" "$DRY_OUT" "$OUT_JSON" "$BRANCH_OUT" \
        "/tmp/zuvo-cli-test-$$.json" 2>/dev/null || true
}
trap _cleanup EXIT

# IC-8 SSH flag string — verbatim per spec (StrictHostKeyChecking=yes).
IC8_FLAGS='-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes -o StrictHostKeyChecking=yes'

# Mutating command patterns that MUST NOT appear in a dry-run (after /tmp/zuvo- filter).
MUTATING_RE='apt(-get)? install|sysctl -w|chmod |chown |rm |mv |tee |> /etc'

# ---------------------------------------------------------------------------
# 0. Script exists (RED gate)
# ---------------------------------------------------------------------------
assert_file_exists "$COLLECTOR"
pass "collector script exists: scripts/infra-collect.sh"

# ---------------------------------------------------------------------------
# 1. Missing --host → exit 1 + usage on stderr
# ---------------------------------------------------------------------------
ERR_FILE="$(mktemp)"
set +e
bash "$COLLECTOR" --out /tmp/zuvo-cli-test-$$.json >/dev/null 2>"$ERR_FILE"
RC=$?
set -e
require_eq "$RC" "1" "missing --host should exit 1"
if ! grep -qiE 'usage' "$ERR_FILE"; then
  fail "missing --host: expected 'usage' on stderr, got: $(cat "$ERR_FILE")"
fi
pass "missing --host → exit 1 + usage on stderr"

# ---------------------------------------------------------------------------
# 2. Malformed --host (`nouser`, `user@`) → exit 1
# ---------------------------------------------------------------------------
for BAD in "nouser" "user@"; do
  set +e
  bash "$COLLECTOR" --host "$BAD" --out /tmp/zuvo-cli-test-$$.json >/dev/null 2>&1
  RC=$?
  set -e
  require_eq "$RC" "1" "malformed --host '$BAD' should exit 1"
  pass "malformed --host '$BAD' → exit 1"
done

# ---------------------------------------------------------------------------
# 3. --out into unwritable parent → exit 1 BEFORE any connection
# ---------------------------------------------------------------------------
set +e
T0=$(date +%s)
bash "$COLLECTOR" --host u@192.0.2.1 --out /nonexistent/x.json >/dev/null 2>&1
RC=$?
T1=$(date +%s)
set -e
require_eq "$RC" "1" "--out into unwritable parent should exit 1"
if [ $((T1 - T0)) -ge 3 ]; then
  fail "--out validation took $((T1 - T0))s — should fail-fast before any connection"
fi
pass "--out into unwritable parent → exit 1 fast (before any connection)"

# ---------------------------------------------------------------------------
# 4. Static grep: `command -v jq` hard gate present in script
# ---------------------------------------------------------------------------
require_grep 'command -v jq' "$COLLECTOR"
pass "command -v jq hard gate present in script"

# ---------------------------------------------------------------------------
# 5. --dry-run --no-install: exit 0, prints WOULD-run commands, <5s wall,
#    no mutating commands, consent-install block absent.
# ---------------------------------------------------------------------------
OUT_JSON="/tmp/zuvo-cli-test-$$.json"
DRY_OUT="$(mktemp)"
set +e
T0=$(date +%s)
bash "$COLLECTOR" --dry-run --no-install --host u@192.0.2.1 --out "$OUT_JSON" >"$DRY_OUT" 2>&1
RC=$?
T1=$(date +%s)
set -e
require_eq "$RC" "0" "dry-run --no-install should exit 0"
pass "dry-run --no-install → exit 0"

if [ $((T1 - T0)) -ge 5 ]; then
  fail "dry-run took $((T1 - T0))s — must be <5s (no connections)"
fi
pass "dry-run completes in <5s (no connections)"

# prints commands it WOULD run
if ! grep -qiE 'would|dry-run|\[DRY' "$DRY_OUT"; then
  fail "dry-run output should announce the commands it WOULD run"
fi
pass "dry-run prints the commands it WOULD run"

# mutating-command scan, after filtering /tmp/zuvo- scratch-dir lines
MUT_COUNT="$(grep -vE '/tmp/zuvo-' "$DRY_OUT" | grep -cE "$MUTATING_RE" || true)"
MUT_COUNT="$(echo "$MUT_COUNT" | tr -d ' ')"
require_eq "$MUT_COUNT" "0" "dry-run emitted mutating command(s): $(grep -vE '/tmp/zuvo-' "$DRY_OUT" | grep -E "$MUTATING_RE")"
pass "dry-run emits ZERO mutating commands (apt/sysctl -w/chmod/chown/rm/mv/tee/> /etc)"

# consent-install block absent under --no-install
if grep -qiE 'consent.*install|install.*consent|proceed with install|y/n.*install' "$DRY_OUT"; then
  fail "consent-install block present under --no-install (should be absent)"
fi
pass "consent-install block ABSENT under --no-install"

# ---------------------------------------------------------------------------
# 6. Every printed `ssh` line contains the FULL IC-8 flag string
# ---------------------------------------------------------------------------
SSH_LINES="$(grep -nE '(^|[^[:alnum:]])ssh ' "$DRY_OUT" || true)"
if [ -z "$SSH_LINES" ]; then
  fail "dry-run printed no ssh lines — expected the IC-8 ssh prefix on remote commands"
fi
BAD_SSH=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! echo "$line" | grep -Fq -- "$IC8_FLAGS"; then
    echo "  ssh line missing IC-8 flags: $line"
    BAD_SSH=$((BAD_SSH + 1))
  fi
done <<< "$SSH_LINES"
require_eq "$BAD_SSH" "0" "ssh lines missing full IC-8 flag string: $BAD_SSH"
pass "every printed ssh line contains the full IC-8 flag string (StrictHostKeyChecking=yes)"

# ---------------------------------------------------------------------------
# 7. Every printed `find` line contains `-xdev`
# ---------------------------------------------------------------------------
FIND_LINES="$(grep -nE '(^|[^[:alnum:]])find ' "$DRY_OUT" || true)"
if [ -z "$FIND_LINES" ]; then
  fail "dry-run printed no find lines — expected bounded find for IS11/IS12"
fi
BAD_FIND=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! echo "$line" | grep -Fq -- '-xdev'; then
    echo "  find line missing -xdev: $line"
    BAD_FIND=$((BAD_FIND + 1))
  fi
done <<< "$FIND_LINES"
require_eq "$BAD_FIND" "0" "find lines missing -xdev: $BAD_FIND"
pass "every printed find line contains -xdev"

# ---------------------------------------------------------------------------
# 8. Static greps on the script: single SSH_OPTS, named constants, SED_REDACT
# ---------------------------------------------------------------------------
require_grep '^[[:space:]]*SSH_OPTS=' "$COLLECTOR"
pass "SSH_OPTS= constant defined in script"

# The full IC-8 literal must appear exactly ONCE (defined once, interpolated everywhere)
FLAG_LIT_COUNT="$(grep -cF -- "$IC8_FLAGS" "$COLLECTOR" || true)"
FLAG_LIT_COUNT="$(echo "$FLAG_LIT_COUNT" | tr -d ' ')"
require_eq "$FLAG_LIT_COUNT" "1" "IC-8 flag literal appears $FLAG_LIT_COUNT times — must be 1 (defined once, no duplication)"
pass "IC-8 flag literal appears exactly once in script (no duplicated flag literals)"

for CONST in CHECK_TIMEOUT_S TRIVY_TIMEOUT_S CONNECT_TIMEOUT_S WALL_CLOCK_LIMIT_S SED_REDACT; do
  require_grep "$CONST" "$COLLECTOR"
  pass "named constant present: $CONST"
done

# ---------------------------------------------------------------------------
# 9. Dry-run wrote the bundle SKELETON to --out — validate with jq
# ---------------------------------------------------------------------------
assert_file_exists "$OUT_JSON"
pass "dry-run wrote bundle skeleton to --out"

if ! jq -e . "$OUT_JSON" >/dev/null 2>&1; then
  fail "bundle skeleton is not valid JSON: $(cat "$OUT_JSON")"
fi
pass "bundle skeleton is valid JSON"

# required top-level keys
for KEY in host collected_at privilege_mode tool_availability tools_installed_this_run checks external; do
  if ! jq -e "has(\"$KEY\")" "$OUT_JSON" >/dev/null 2>&1; then
    fail "bundle skeleton missing required key: $KEY"
  fi
  pass "bundle skeleton has required key: $KEY"
done

# tool_availability includes grype
if ! jq -e '.tool_availability | has("grype")' "$OUT_JSON" >/dev/null 2>&1; then
  fail "tool_availability missing grype key"
fi
pass "tool_availability includes grype key"

# every checks[].id matches ^IS([1-9]|1[0-2])-
BAD_IDS="$(jq -r '.checks[].id' "$OUT_JSON" | grep -vE '^IS([1-9]|1[0-2])-' || true)"
if [ -n "$BAD_IDS" ]; then
  fail "checks[].id not matching ^IS([1-9]|1[0-2])-: $BAD_IDS"
fi
CHECK_COUNT="$(jq -r '.checks | length' "$OUT_JSON")"
if [ "$CHECK_COUNT" -lt 1 ]; then
  fail "bundle skeleton checks[] is empty"
fi
pass "all $CHECK_COUNT checks[].id match ^IS([1-9]|1[0-2])-"

# at least one check per dimension IS1..IS12
MISSING_DIMS=""
for N in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if ! jq -e --arg d "IS$N" 'any(.checks[]; .dimension == $d)' "$OUT_JSON" >/dev/null 2>&1; then
    MISSING_DIMS="$MISSING_DIMS IS$N"
  fi
done
if [ -n "$MISSING_DIMS" ]; then
  fail "bundle skeleton missing checks for dimensions:$MISSING_DIMS"
fi
pass "bundle skeleton has ≥1 check per dimension IS1..IS12"

# external.vantage ∈ proxy|direct|none|failed (skeleton: none)
VANTAGE="$(jq -r '.external.vantage' "$OUT_JSON")"
case "$VANTAGE" in
  proxy|direct|none|failed) : ;;
  *) fail "external.vantage '$VANTAGE' not in {proxy,direct,none,failed}" ;;
esac
require_eq "$VANTAGE" "none" "skeleton external.vantage should be 'none'"
pass "external.vantage = none (valid enum)"

# ---------------------------------------------------------------------------
# 10. Branch test: --quick → bundle unique dimensions == ["IS1","IS3","IS4"]
# ---------------------------------------------------------------------------
BRANCH_OUT="$(mktemp)"
set +e
bash "$COLLECTOR" --dry-run --no-install --quick --host u@192.0.2.1 --out "$BRANCH_OUT" >/dev/null 2>&1
RC=$?
set -e
require_eq "$RC" "0" "--quick dry-run should exit 0"

QUICK_DIMS_ACTUAL="$(jq -r '[.checks[].dimension] | unique | sort | @json' "$BRANCH_OUT")"
require_eq "$QUICK_DIMS_ACTUAL" '["IS1","IS3","IS4"]' "--quick bundle dimensions should be [\"IS1\",\"IS3\",\"IS4\"]"
pass "--quick → bundle unique dimensions == [\"IS1\",\"IS3\",\"IS4\"]"

# ---------------------------------------------------------------------------
# 11. Branch test: --dimensions IS1,IS9 → bundle unique dimensions == ["IS1","IS9"]
# ---------------------------------------------------------------------------
set +e
bash "$COLLECTOR" --dry-run --no-install --dimensions IS1,IS9 --host u@192.0.2.1 --out "$BRANCH_OUT" >/dev/null 2>&1
RC=$?
set -e
require_eq "$RC" "0" "--dimensions IS1,IS9 dry-run should exit 0"

DIM_ACTUAL="$(jq -r '[.checks[].dimension] | unique | sort | @json' "$BRANCH_OUT")"
require_eq "$DIM_ACTUAL" '["IS1","IS9"]' "--dimensions IS1,IS9 bundle dimensions should be [\"IS1\",\"IS9\"]"
pass "--dimensions IS1,IS9 → bundle unique dimensions == [\"IS1\",\"IS9\"]"

# ---------------------------------------------------------------------------
# 12. Branch test: malformed port user@h:99999 → exit 1
# ---------------------------------------------------------------------------
set +e
bash "$COLLECTOR" --host "user@h:99999" --out "$BRANCH_OUT" >/dev/null 2>&1
RC=$?
set -e
require_eq "$RC" "1" "malformed port user@h:99999 should exit 1"
pass "malformed port user@h:99999 → exit 1"

# ---------------------------------------------------------------------------
# 13. SSH option injection: host whose user part begins with `-` → exit 1.
#     `-x@host` would otherwise let ssh parse the destination as an option.
# ---------------------------------------------------------------------------
set +e
bash "$COLLECTOR" --host "-x@host" --out "$BRANCH_OUT" >/dev/null 2>&1
RC=$?
set -e
require_eq "$RC" "1" "host with leading-dash user '-x@host' should exit 1 (SSH option injection)"
pass "malformed host '-x@host' (SSH option injection) → exit 1"

# ---------------------------------------------------------------------------
# 14. --run-id command injection: a value with shell metacharacters → exit 1.
#     `x;touch /tmp/pwn` lands inside remote `sh -c` strings — must be rejected.
# ---------------------------------------------------------------------------
set +e
bash "$COLLECTOR" --dry-run --no-install --run-id 'x;touch /tmp/pwn' \
  --host u@192.0.2.1 --out "$BRANCH_OUT" >/dev/null 2>&1
RC=$?
set -e
require_eq "$RC" "1" "malformed --run-id 'x;touch /tmp/pwn' should exit 1 (command injection)"
pass "malformed --run-id 'x;touch /tmp/pwn' (command injection) → exit 1"

# ---------------------------------------------------------------------------
# 15. Valid --run-id (safe charset) is accepted → dry-run exit 0.
# ---------------------------------------------------------------------------
set +e
bash "$COLLECTOR" --dry-run --no-install --run-id 'abc-123' \
  --host u@192.0.2.1 --out "$BRANCH_OUT" >/dev/null 2>&1
RC=$?
set -e
require_eq "$RC" "0" "valid --run-id 'abc-123' dry-run should exit 0"
pass "valid --run-id 'abc-123' accepted → dry-run exit 0"

# ---------------------------------------------------------------------------
# 16. Static grep: every `ssh` invocation in the SCRIPT carries `--` before the
#     destination (SSH option-injection end-of-options guard).
# ---------------------------------------------------------------------------
SSH_INVOCATIONS="$(grep -nE 'ssh \$?SSH_OPTS|ssh %s -p' "$COLLECTOR" || true)"
if [ -z "$SSH_INVOCATIONS" ]; then
  fail "no ssh invocation lines found in script — expected at least the IC-8 dispatch"
fi
BAD_DASH=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if ! echo "$line" | grep -Fq -- ' -- '; then
    echo "  ssh invocation missing ' -- ' end-of-options guard: $line"
    BAD_DASH=$((BAD_DASH + 1))
  fi
done <<< "$SSH_INVOCATIONS"
require_eq "$BAD_DASH" "0" "ssh invocations missing ' -- ' guard: $BAD_DASH"
pass "every ssh invocation in script carries ' -- ' before the destination"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "ALL INFRA-COLLECTOR-CLI ASSERTIONS PASSED"
