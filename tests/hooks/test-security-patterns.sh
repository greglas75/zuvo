#!/usr/bin/env bash
# Guards the defensive patterns that agents COPY into production code. A wrong example here
# ships the bug everywhere it is pasted, so these are asserted two ways: the prose must not
# re-introduce the broken form, and the prescribed code is EXECUTED to prove it behaves.
#
# All three were live defects found by a cross-model review on 2026-07-27:
#   - CQ28 timeout hierarchy was inverted (client < server < DB) in 7 places
#   - timingSafeEqual on raw buffers THROWS on length mismatch (500 + length oracle)
#   - path.normalize()+startsWith() passes /var/data-evil for base /var/data
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ---------- 1. timeout hierarchy direction ----------
# The deadline must SHRINK with depth: DB < server < client. Inverted, the client aborts first
# and the DB keeps a pooled connection for a request nobody awaits.
if grep -rIl --include='*.md' -E 'client[ _]?(timeout)?[ ]*<[ ]*server' \
     "$ROOT/rules" "$ROOT/shared/includes" "$ROOT/docs" "$ROOT/skills" 2>/dev/null | grep -q .; then
  bad "inverted timeout hierarchy (client < server) reintroduced"
else
  pass "timeout hierarchy states DB < server < client everywhere"
fi
grep -q 'DB < server < client' "$ROOT/rules/cq-patterns.md" \
  && pass "cq-patterns documents the correct direction" || bad "cq-patterns lost the direction statement"

# ---------- 2. timingSafeEqual must never receive raw, unequal-length buffers ----------
grep -qE 'timingSafeEqual\(Buffer\.from\([a-z]+\), *Buffer\.from\(' "$ROOT/rules/cq-patterns-core.md" \
  && bad "core prescribes timingSafeEqual on raw buffers (throws on length mismatch)" \
  || pass "core no longer prescribes raw-buffer timingSafeEqual"
grep -qE '^\s*if \(a\.length !== b\.length \|\|' "$ROOT/rules/cq-patterns.md" \
  && bad "length short-circuit reintroduced (leaks the length it exists to hide)" \
  || pass "no length short-circuit around timingSafeEqual"

if command -v node >/dev/null 2>&1; then
  # Execute the prescribed pattern: must return false (not throw) on a length mismatch.
  out=$(node -e '
    const { createHash, timingSafeEqual } = require("node:crypto");
    const digest = (s) => createHash("sha256").update(s, "utf8").digest();
    const eq = (a,b) => timingSafeEqual(digest(a), digest(b));
    if (eq("secret","secret") !== true) { console.log("BAD-equal"); process.exit(0); }
    if (eq("secret","wrong-length-token") !== false) { console.log("BAD-unequal"); process.exit(0); }
    console.log("OK");' 2>&1)
  [ "$out" = "OK" ] && pass "prescribed secret compare runs: equal=true, unequal=false, no throw" \
                    || bad "prescribed secret compare misbehaves: $out"

  # Execute the prescribed path guard against the exact escape that defeated the old one.
  out=$(node -e '
    const path = require("node:path");
    // MUST mirror the guard prescribed in rules/cq-patterns.md — segment compare, not prefix.
    const blocked = (base, input) => {
      const b = path.resolve(base), t = path.resolve(b, input), rel = path.relative(b, t);
      return rel === "" || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel);
    };
    // legitimate paths, including a file whose NAME starts with ".." — a bare
    // rel.startsWith("..") would wrongly reject these.
    for (const ok of ["ok/file.txt", "..config", "..hidden/a.txt"])
      if (blocked("/var/data", ok) !== false) { console.log("BAD-legit-blocked:" + ok); process.exit(0); }
    for (const esc of ["../data-evil/secret.txt", "../../etc/passwd", "/etc/passwd"])
      if (blocked("/var/data", esc) !== true) { console.log("BAD-escape-allowed:" + esc); process.exit(0); }
    console.log("OK");' 2>&1)
  [ "$out" = "OK" ] && pass "prescribed path guard blocks prefix-collision and absolute escapes" \
                    || bad "prescribed path guard misbehaves: $out"
else
  printf 'SKIP: node absent — pattern-execution checks not run\n'
fi

# ---------- 3. path guard prose ----------
grep -qE 'normalize\(\).*startsWith\(baseDir\)' "$ROOT/rules/cq-patterns-core.md" \
  && bad "core still prescribes normalize()+startsWith() (passes /base-evil for /base)" \
  || pass "core prescribes resolve()+relative() containment"

# ---------- 4. N/A anti-gaming rules ----------
CQ="$ROOT/rules/cq-checklist.md"
grep -q 'N/A cannot raise the score' "$CQ" && pass "N/A anti-gaming rule present" || bad "N/A anti-gaming rule missing"
grep -q 'same evidence rigour as a 0' "$CQ" && pass "N/A requires negative-evidence citation" || bad "N/A evidence rule missing"
grep -qi 'may not go below 20\|INCOMPLETE' "$CQ" && pass "denominator floor / INCOMPLETE verdict defined" || bad "no denominator floor"

# The attack must not pay: 20 pass / 9 fail stays FAIL after re-labelling 6 failures as N/A.
grep -q 'Honest limit' "$CQ" && pass "discloses that the N/A rules are agent-followed, not mechanical" \
  || bad "N/A enforcement limit not disclosed"

# ---------- 5. gate count ----------
grep -rIn --include='*.md' -E 'of 28 for CQ|any of the 28 gates|ALL 28 gates' \
  "$ROOT/rules" "$ROOT/shared/includes" "$ROOT/docs/quality-gates.md" "$ROOT/skills" 2>/dev/null | grep -q . \
  && bad "stale 28-gate reference (there are 29 CQ gates)" || pass "no stale 28-gate references"

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
