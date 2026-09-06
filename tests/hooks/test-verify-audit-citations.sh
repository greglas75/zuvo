#!/usr/bin/env bash
# Medium integration test for verify-audit's citation pattern (isolated filesystem + git).
#
# Why this exists: the pattern required a file EXTENSION from a fixed list, and this repo ships its
# Python helpers WITHOUT one — `scripts/zuvo-home/poll-cost` carries a polyglot sh/python header
# because `#!/usr/bin/env python3` does not resolve on Windows. So a finding about any of those
# files could not be verified however correct it was, and the only ways past the gate were a fake
# citation to a neighbouring file or the audited override. Both defeat the gate rather than pass it.
#
# The widening must not become a hole: a citation still has to resolve to a real file, inside the
# project, at a line that exists. The negative cases below are the point of this file.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/verify-audit"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$BIN" ] || { bad "scripts/zuvo-home/verify-audit does not exist"; exit 1; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
# Root discovery follows the report, so create a real repository around it. Never rely on
# the source checkout's .git (absent on rt) or write probes into its review history.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
unset ZUVO_SKIP_AUDIT_VERIFY
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/memory/reviews" "$FIXTURE/scripts/zuvo-home" "$FIXTURE/tests/hooks"
git -C "$FIXTURE" init -q || exit 1
cp "$ROOT/scripts/zuvo-home/poll-cost" "$FIXTURE/scripts/zuvo-home/poll-cost"
cp "$ROOT/tests/hooks/test-verify-audit-citations.sh" "$FIXTURE/tests/hooks/test-verify-audit-citations.sh"
git -C "$FIXTURE" add scripts/zuvo-home/poll-cost tests/hooks/test-verify-audit-citations.sh || exit 1
git -C "$FIXTURE" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null commit -qm fixture || exit 1
PROBE="$FIXTURE/memory/reviews/probe.md"
SHA=$(git -C "$FIXTURE" rev-parse --short=7 HEAD) || exit 1

report() {   # report <citation>  → writes a one-finding report, echoes verify-audit output
  cat > "$PROBE" <<EOF
# Review — probe

**R-1 [MUST-FIX] probe finding**
  File: \`$1\`
  Verified-against: $SHA
  Evidence: synthetic.
EOF
  ( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 )
}

# ── 1. an extensionless helper IS citable ────────────────────────────────────
lines=$(wc -l < "$FIXTURE/scripts/zuvo-home/poll-cost" | tr -d ' ')
out=$(report "scripts/zuvo-home/poll-cost:$((lines / 2))"); rc=$?
[ "$rc" -eq 0 ] && grep -q "unverified:        0" <<< "$out" \
  && pass "an extensionless polyglot helper can be cited" \
  || bad "extensionless citation rejected: $(echo "$out" | tail -3)"

# ── 2. a line past the end of that file is still rejected ────────────────────
out=$(report "scripts/zuvo-home/poll-cost:$((lines + 5000))"); rc=$?
[ "$rc" -eq 2 ] && grep -q "out of range" <<< "$out" \
  && pass "an out-of-range line is rejected even without an extension" \
  || bad "out-of-range line accepted: $(echo "$out" | tail -3)"

# ── 3. a path that does not exist is still rejected ──────────────────────────
out=$(report "scripts/zuvo-home/no-such-helper:3"); rc=$?
[ "$rc" -eq 2 ] && grep -q "does not exist" <<< "$out" \
  && pass "a non-existent extensionless path is rejected" \
  || bad "non-existent path accepted: $(echo "$out" | tail -3)"

# ── 4. a bare word is not a citation ─────────────────────────────────────────
# The widened shape requires a directory separator, so prose like `step 3: 12` cannot masquerade
# as a citation and silently satisfy the gate.
out=$(report "someword:12"); rc=$?
[ "$rc" -eq 2 ] && grep -q "no file:line citation" <<< "$out" \
  && pass "a bare word with no separator is not treated as a citation" \
  || bad "a bare word satisfied the citation requirement: $(echo "$out" | tail -3)"

# ── 5. a URL is not a citation ───────────────────────────────────────────────
out=$(report "https://example.com/x:12"); rc=$?
[ "$rc" -eq 2 ] && grep -qE "no file:line citation|does not exist|path escapes" <<< "$out" \
  && pass "a URL does not satisfy the citation requirement" \
  || bad "a URL was accepted as a citation: $(echo "$out" | tail -3)"

# ── 6. the original extension shape still works ──────────────────────────────
out=$(report "tests/hooks/test-verify-audit-citations.sh:5"); rc=$?
[ "$rc" -eq 0 ] && grep -q "unverified:        0" <<< "$out" \
  && pass "a conventional .sh citation still verifies" \
  || bad "the pre-existing shape regressed: $(echo "$out" | tail -3)"

# Advancing the fixture HEAD must invalidate a previously valid stamp. This proves
# the positive cases did not pass through the verifier's no-git fallback.
git -C "$FIXTURE" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null commit --allow-empty -qm advance || exit 1
out=$(report "scripts/zuvo-home/poll-cost:1"); rc=$?
[ "$rc" -eq 2 ] && grep -q "does not match current SHA" <<< "$out" \
  && pass "a stale stamp is rejected against the fixture HEAD" \
  || bad "stale stamp accepted or wrong failure: $out"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
