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

# ── a report kept in the MAIN checkout, verified from a linked worktree, is checked against the worktree ──
# A linked worktree's memory/reviews is often the main checkout's (a symlink, or the gate's fallback). Its
# findings cite the worktree's branch; resolving the root from the report's location checked them against
# whatever the main checkout had out, and every citation of a new file came back "does not exist".
WM="$TMP/wm"; mkdir -p "$WM"
git -C "$WM" init -q -b main && git -C "$WM" -c user.name=T -c user.email=t@t commit -q --allow-empty -m base || exit 1
git -C "$WM" worktree add -q -b feat "$TMP/wm-wt" || exit 1
mkdir -p "$TMP/wm-wt/src" && printf 'x = 1\ny = 2\n' > "$TMP/wm-wt/src/only.py"
git -C "$TMP/wm-wt" add src/only.py && git -C "$TMP/wm-wt" -c user.name=T -c user.email=t@t commit -qm only || exit 1
mkdir -p "$WM/memory/reviews"
cat > "$WM/memory/reviews/wt.md" <<EOF
# Review — worktree
**R-1 [MUST-FIX] probe finding**
  File: \`src/only.py:2\`
  Verified-against: $(git -C "$TMP/wm-wt" rev-parse --short=7 HEAD)
  Evidence: synthetic.
EOF
out=$( cd "$TMP/wm-wt" && python3 "$BIN" "$WM/memory/reviews/wt.md" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && grep -q "unverified:        0" <<< "$out" \
  && pass "a report in the main checkout, verified from the linked worktree, resolves against the worktree" \
  || bad "worktree report from the main checkout: rc=$rc out=$out"
out=$( cd "$WM" && python3 "$BIN" "$WM/memory/reviews/wt.md" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && grep -q "does not exist\|not exist\|does not match" <<< "$out" \
  && pass "control: verified from the main checkout itself, the same report is checked against main (the file is not there)" \
  || bad "main-checkout control: rc=$rc out=$out"
out=$( cd "$FIXTURE" && python3 "$BIN" "$WM/memory/reviews/wt.md" 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && grep -q "Current SHA: $(git -C "$WM" rev-parse --short HEAD)" <<< "$out" \
  && pass "control: from ANOTHER repository's checkout the report keeps its own root, the main checkout (a different git common dir)" \
  || bad "foreign-repo control: rc=$rc out=$out"

# ── D3 (live review test 2026-11-21): the SKILL's own finding example parsed to zero findings ──
# `R-1 [MUST-FIX] title` with no `##`/`**`/`-` opener matched nothing, and a report of such findings
# exited 0 having verified nothing.
lines=$(wc -l < "$FIXTURE/scripts/zuvo-home/poll-cost" | tr -d ' ')
cat > "$PROBE" <<EOF
# Review — bare shape

R-1 [MUST-FIX] bare finding
  File: \`scripts/zuvo-home/poll-cost:$((lines + 5000))\`
  Verified-against: $SHA
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "out of range" <<< "$out" \
  && pass "D3: a bare 'R-1 [MUST-FIX]' finding is parsed and its citation checked" \
  || bad "D3: bare-shape finding not verified (rc=$rc): $(echo "$out" | tail -2)"
cat > "$PROBE" <<EOF
# Review — unparseable

1) [MUST-FIX] tenant filter dropped (see scripts/zuvo-home/poll-cost:3)
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && pass "D3: severity-tagged findings that parse to zero sections are rejected, not passed vacuously" \
  || bad "D3: unparseable tagged findings exited $rc (vacuous pass)"
# A clean report mentions a severity tag and a file:line in different places: not a finding (the first
# D3 fix rejected it with a whole-file co-occurrence check).
cat > "$PROBE" <<EOF
# Review — clean

0 [MUST-FIX] findings. DEPLOYMENT RISK [LOW]: none.
QUALITY WINS: scripts/zuvo-home/poll-cost:3 reads cleanly.
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && pass "D3: a clean report with a tag and a citation in different lines is not rejected" \
  || bad "D3: clean report rejected (rc=$rc): $(echo "$out" | tail -2)"
# 'R-1 — [MUST-FIX] title' (dash before the tag) is a header too, so its citation is checked.
cat > "$PROBE" <<EOF
# Review — dash shape

R-1 — [MUST-FIX] dashed finding
  File: \`scripts/zuvo-home/poll-cost:$((lines + 5000))\`
  Verified-against: $SHA
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "out of range" <<< "$out" \
  && pass "D3: 'R-1 — [MUST-FIX]' is parsed and its citation checked" \
  || bad "D3: dash-shape finding not verified (rc=$rc): $(echo "$out" | tail -2)"

# Round-2 review: a tag-only line with the citation on the NEXT line was passed as "0 findings".
cat > "$PROBE" <<EOF
# Review — tag then citation

- [MUST-FIX] tenant filter dropped in the list query
  scripts/zuvo-home/poll-cost:3
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] \
  && pass "D3: a tagged line whose citation is on the next line is rejected, not passed vacuously" \
  || bad "D3: tag-then-citation report exited $rc"
# One parsed finding must not vouch for a second, unparsed one in the same report.
cat > "$PROBE" <<EOF
# Review — mixed

## R-1 — parsed finding
  File: \`scripts/zuvo-home/poll-cost:3\`
  Verified-against: $SHA

1) [MUST-FIX] second finding the header grammar skips (scripts/zuvo-home/poll-cost:$((lines + 5000)))
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "not in a recognised header shape" <<< "$out" \
  && pass "D3: an unparsed tagged finding next to a parsed one is rejected, its citation never verified" \
  || bad "D3: mixed report exited $rc: $(echo "$out" | tail -2)"
SHA=$(git -C "$FIXTURE" rev-parse --short=7 HEAD)   # earlier cases moved the fixture's HEAD
# Round-2 review (Carbon): a subordinated NIT bullet, and the Pre-existing block's "[NIT] (true severity
# [MUST-FIX])" line, carry a citation and no finding ID. They are not findings the gate verifies, so they
# must not turn a good report into a rejection (exit 0 beside a parsed finding, and in a report that has none).
cat > "$PROBE" <<EOF
# Review — NIT bullets

## R-1 — parsed finding
  File: \`scripts/zuvo-home/poll-cost:3\`
  Verified-against: $SHA

Pre-existing (outside changed lines):
  - [NIT] (true severity [MUST-FIX]) tenant filter missing, scripts/zuvo-home/poll-cost:3
  - [NIT] rename x in scripts/zuvo-home/poll-cost:4
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && pass "D3: NIT bullets with a citation and no ID do not reject a report with a parsed finding" \
  || bad "D3: NIT bullets rejected a good report (rc=$rc): $(echo "$out" | head -8)"
cat > "$PROBE" <<EOF
# Review — NIT only

0 [MUST-FIX] findings.
  - [NIT] rename x in scripts/zuvo-home/poll-cost:4
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && pass "D3: a NIT-only report with a cited bullet is not rejected as unparseable" \
  || bad "D3: NIT-only report rejected (rc=$rc): $(echo "$out" | tail -2)"
# CRITICAL-1 (8-letter prefix) is a header, its citation is checked.
cat > "$PROBE" <<EOF
# Review — long prefix

CRITICAL-1 [CRITICAL] long id finding
  File: \`scripts/zuvo-home/poll-cost:$((lines + 5000))\`
  Verified-against: $SHA
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "out of range" <<< "$out" \
  && pass "D3: an 8-letter finding prefix is parsed and its citation checked" \
  || bad "D3: CRITICAL-1 finding not verified (rc=$rc): $(echo "$out" | tail -2)"

# Round-3: a prefix that is not CRITICAL/HIGH (BLOCKER-1, SECURITY-1) is a header too, and a summary line
# that restates a parsed finding (`- [MUST-FIX] R-1 ... file:line`) is not a second unparsed finding.
cat > "$PROBE" <<EOF
# Review — long non-severity prefix

BLOCKER-1 [MUST-FIX] long id finding
  File: \`scripts/zuvo-home/poll-cost:$((lines + 5000))\`
  Verified-against: $SHA
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 2 ] && grep -q "out of range" <<< "$out" \
  && pass "D3: BLOCKER-1 [MUST-FIX] is parsed as a header and its citation checked" \
  || bad "D3: BLOCKER-1 finding not verified (rc=$rc): $(echo "$out" | tail -2)"
cat > "$PROBE" <<EOF
# Review — summary restates a finding

## R-1 [MUST-FIX] parsed finding
  File: \`scripts/zuvo-home/poll-cost:3\`
  Verified-against: $SHA

Summary:
  - [MUST-FIX] R-1 fixed in scripts/zuvo-home/poll-cost:3
EOF
out=$( cd "$TMP" && python3 "$BIN" "$PROBE" 2>&1 ); rc=$?
[ "$rc" -eq 0 ] \
  && pass "D3: a summary line naming a parsed finding ID is not an unparsed second finding" \
  || bad "D3: summary restatement rejected (rc=$rc): $(echo "$out" | head -6)"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
