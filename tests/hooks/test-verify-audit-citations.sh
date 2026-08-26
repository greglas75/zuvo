#!/usr/bin/env bash
# Contract for verify-audit's citation pattern.
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

TMP="$(mktemp -d)"
# The probe report must live INSIDE the repo: verify-audit derives the project root from the
# REPORT's path, not from the cwd, so a report in /tmp makes every repo-relative citation resolve
# against /tmp and fail. Getting that wrong is how this suite first "proved" a regression that was
# entirely in its own harness.
PROBE="$ROOT/memory/reviews/.probe-verify-audit-$$.md"
trap 'rm -rf "$TMP"; rm -f "$PROBE"' EXIT
mkdir -p "$ROOT/memory/reviews"
SHA=$(git -C "$ROOT" rev-parse --short=7 HEAD)

report() {   # report <citation>  → writes a one-finding report, echoes verify-audit output
  cat > "$PROBE" <<EOF
# Review — probe

**R-1 [MUST-FIX] probe finding**
  File: \`$1\`
  Verified-against: $SHA
  Evidence: synthetic.
EOF
  ( cd "$ROOT" && python3 "$BIN" "$PROBE" 2>&1 )
}

# ── 1. an extensionless helper IS citable ────────────────────────────────────
lines=$(wc -l < "$ROOT/scripts/zuvo-home/poll-cost" | tr -d ' ')
out=$(report "scripts/zuvo-home/poll-cost:$((lines / 2))")
echo "$out" | grep -q "unverified:        0" \
  && pass "an extensionless polyglot helper can be cited" \
  || bad "extensionless citation rejected: $(echo "$out" | tail -3)"

# ── 2. a line past the end of that file is still rejected ────────────────────
out=$(report "scripts/zuvo-home/poll-cost:$((lines + 5000))")
echo "$out" | grep -q "out of range" \
  && pass "an out-of-range line is rejected even without an extension" \
  || bad "out-of-range line accepted: $(echo "$out" | tail -3)"

# ── 3. a path that does not exist is still rejected ──────────────────────────
out=$(report "scripts/zuvo-home/no-such-helper:3")
echo "$out" | grep -q "does not exist" \
  && pass "a non-existent extensionless path is rejected" \
  || bad "non-existent path accepted: $(echo "$out" | tail -3)"

# ── 4. a bare word is not a citation ─────────────────────────────────────────
# The widened shape requires a directory separator, so prose like `step 3: 12` cannot masquerade
# as a citation and silently satisfy the gate.
out=$(report "someword:12")
echo "$out" | grep -q "no file:line citation" \
  && pass "a bare word with no separator is not treated as a citation" \
  || bad "a bare word satisfied the citation requirement: $(echo "$out" | tail -3)"

# ── 5. a URL is not a citation ───────────────────────────────────────────────
out=$(report "https://example.com/x:12")
echo "$out" | grep -qE "no file:line citation|does not exist|path escapes" \
  && pass "a URL does not satisfy the citation requirement" \
  || bad "a URL was accepted as a citation: $(echo "$out" | tail -3)"

# ── 6. the original extension shape still works ──────────────────────────────
out=$(report "tests/hooks/test-verify-audit-citations.sh:5")
echo "$out" | grep -q "unverified:        0" \
  && pass "a conventional .sh citation still verifies" \
  || bad "the pre-existing shape regressed: $(echo "$out" | tail -3)"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
