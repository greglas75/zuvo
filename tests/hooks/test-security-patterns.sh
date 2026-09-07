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
# This checks the actual shipped instruction block and then deletes each protection from
# an isolated in-memory fixture. It guards the contract, not the auditor's source judgement:
# wording alone cannot prove that an auditor really traced a caller or verified a citation.
if python3 - "$ROOT/rules/cq-checklist.md" "$ROOT" <<'PYCQ'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("**Evidence decides applicability;")
contract = source[start:source.index("\n---", start)]
# Each independent clause closes a distinct route to a false PASS. Match complete obligations,
# not the presence of a headline or a stray INCOMPLETE elsewhere in the document.
protections = {
    "inactive feature with source evidence": r"Every N/A records the gate's feature precondition, why it is inactive, and source evidence",
    "source and caller inspection": r"Cite inspected file:symbol:line locations, relevant imports/callers",
    "negative search with result": r"scoped negative search\s+with command and result",
    "unknown or missing evidence stays unproven": r"Missing evidence, an unknown precondition, or an unperformed check is \*\*0 \(unproven\)\*\*,\s+never N/A",
    "high count requires independent review": r"`count\(N/A\)`? > floor\(in_scope / 3\)` requires documented independent applicability review",
    "review validates every exclusion": r"independent CQ auditor rechecks each inactive precondition against source and\s+relevant callers, and records accepted/rejected gate IDs with evidence",
    "pending review is incomplete": r"Until that check\s+completes, verdict is `INCOMPLETE`",
    "verified pure modules are not rejected by count": r"Once verified, a high count alone does not prohibit PASS",
    "active failures cannot be renamed": r"All active critical gates remain mandatory; a failed one cannot be relabelled N/A",
    "unproven remains in denominator": r"Exclude N/A from both numerator and denominator; keep 0/unproven in the denominator",
    "honest enforcement limits": r"Honest limit.*?evidence requirements, not mechanical proof of source semantics",
}

def missing(text):
    return [name for name, pattern in protections.items()
            if re.search(pattern, text, re.DOTALL) is None]

errors = missing(contract)
if errors:
    raise SystemExit("FAIL: missing CQ applicability protection: " + "; ".join(errors))
for name, pattern in protections.items():
    weakened, edits = re.subn(pattern, "REMOVED OBLIGATION", contract, count=1, flags=re.DOTALL)
    if edits != 1 or name not in missing(weakened):
        raise SystemExit("FAIL: negative fixture did not detect removal of: " + name)
    print("PASS: applicability contract rejects removed protection: " + name)
print("PASS: shipped CQ applicability contract preserves evidence, review and active-failure safeguards")

# Runtime skill notes and public docs must not reintroduce superseded guidance beside the
# canonical rules. Append the old instructions to valid text to prove conflicts are rejected.
root = pathlib.Path(sys.argv[2])
docs = (root / "docs/quality-gates.md").read_text(encoding="utf-8")
na_section = docs.split("## N/A abuse prevention\n", 1)[1].split("\n---", 1)[0]
skill = (root / "skills/code-audit/SKILL.md").read_text(encoding="utf-8")
cq8_note = next(line for line in skill.splitlines() if line.startswith("CQ8 NOTE:"))

def valid_na_copy(text):
    return (all(term in text for term in (
        "independent applicability", "Pending review", "INCOMPLETE",
        "verified high count alone does not prohibit PASS", "0/unproven"))
        and not re.search(r"may not exceed|one-third cap|code type can never be N/A", text))

def valid_cq8_copy(text):
    return (all(term in text for term in (
        "every entry point", "HTTP", "queue/cron/CLI", "detached promises",
        "timeouts", "response.ok", "async rejection", "CQ8=0"))
        and not re.search(r"= CQ8 PASS|Only CQ8=0 when errors are swallowed", text))

for name, check, actual, old_rule in (
    ("docs CQ N/A", valid_na_copy, na_section, "`count(N/A)` may not exceed one-third cap"),
    ("code-audit CQ8", valid_cq8_copy, cq8_note,
     "If global error handler exists, services that let errors propagate = CQ8 PASS. Only CQ8=0 when errors are swallowed."),
):
    if not check(actual) or check(actual + "\n" + old_rule):
        raise SystemExit("FAIL: copied guidance regression: " + name)
    print("PASS: copied guidance rejects restored obsolete rule: " + name)

PYCQ
then
  pass "CQ applicability protections and negative fixtures"
else
  bad "CQ applicability contract or negative fixtures failed"
fi

# ---------- 5. gate count ----------
grep -rIn --include='*.md' -E 'of 28 for CQ|any of the 28 gates|ALL 28 gates' \
  "$ROOT/rules" "$ROOT/shared/includes" "$ROOT/docs/quality-gates.md" "$ROOT/skills" 2>/dev/null | grep -q . \
  && bad "stale 28-gate reference (there are 29 CQ gates)" || pass "no stale 28-gate references"

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
