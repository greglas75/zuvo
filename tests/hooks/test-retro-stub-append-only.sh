#!/usr/bin/env bash
# retro-stub must be APPEND-ONLY — the truncation that went unattributed for three days.
#
# The incident: from 2026-08-16 to 2026-08-18 retros.log was cut to exactly 100 rows roughly once
# a day (626 -> 100 on 08-18 14:45:07Z, 543 -> 100 on 08-18 03:36:40Z, 519 -> 19 on 08-17), and
# retros.md fell from 585 sections to 127 and then 122. append-retro's shrink guard caught every
# event and auto-recovered, and retro-shrink-forensics.sh dumped the process table each time, but
# neither could name the writer: the truncation happened INSIDE a legitimate append, under the
# retro lock, from retro-stub's own `tail -n 100` / 100-section awk window.
#
# append-retro had dropped that cap (its rationale is in the file, and retrospective.md says "Do
# not reintroduce a count cap"); retro-stub kept a copy. Because it runs from session-start, the
# Stop retro sweep and the pre-commit gate, ~100 stub writes a day each rolled the dice on a file
# over 101 lines. `retro-mine.py --days 7` could never see its own window.
#
# So this suite asserts the BEHAVIOR (drive the real script, count rows before/after) and then the
# CLASS (no count-based cap anywhere in the source), because the behavioral test only proves the
# instance at line 120 is gone — a new one added elsewhere would pass it right up to the row that
# crosses the threshold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB="$ROOT/scripts/zuvo-home/retro-stub"
APPEND="$ROOT/scripts/zuvo-home/append-retro"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

bash -n "$STUB" 2>/dev/null && ok "retro-stub parses" || bad "retro-stub does not parse"

Z="$TMP/z"; mkdir -p "$Z"
export ZUVO_HOME="$Z"
row(){ printf 'RETRO: 2026-08-%02dT00:00:%02dZ\tship\tproj-%s\tOTHER\tother\tN/A\tnone\t1\t1\t1\t1\tmain\tsha%04d\tN/A\tN/A\tN/A\tok\n' \
  "$(( (${1} % 28) + 1 ))" "$(( ${1} % 60 ))" "$1" "$1"; }
rows(){ grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null | head -1; }
secs(){ grep -c '^<!-- RETRO -->' "$Z/retros.md" 2>/dev/null | head -1; }

# 300 rows and 300 sections: comfortably past both former caps (101 lines / 100 sections), and
# past what a single stub write could plausibly need.
{
  echo "# v2 DATE SKILL PROJECT CODE_TYPE FRICTION_CATEGORY MISSING_TEMPLATE CONTEXT_GAP TURNS_WASTED TOOL_CALLS FILES_READ FILES_MODIFIED BRANCH SHA7 BLIND_AUDIT ADVERSARIAL CODESIFT ROUTING_STATUS"
  for i in $(seq 1 300); do row "$i"; done
} > "$Z/retros.log"
{
  echo "# retros"
  for i in $(seq 1 300); do printf '<!-- RETRO -->\n\n## [%s] entry %s\n\n' "2026-08-01" "$i"; done
} > "$Z/retros.md"

BEFORE_ROWS=$(rows); BEFORE_SECS=$(secs)
[ "$BEFORE_ROWS" = "300" ] && [ "$BEFORE_SECS" = "300" ] \
  && ok "fixture built (300 rows, 300 sections)" \
  || { bad "fixture wrong (rows=$BEFORE_ROWS secs=$BEFORE_SECS)"; echo "FAILED: $fails"; exit 1; }

# A stub for a skill+project+SHA7 not present above, so the idempotency no-op does not fire.
bash "$STUB" --status=ABANDONED --skill=execute --project=append-only-probe \
  --friction=pipeline-heavy --turns=3 --tool-calls=9 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 0 ] && ok "stub write exits 0" || bad "stub write exited $rc ($(head -2 "$TMP/err"))"

AFTER_ROWS=$(rows); AFTER_SECS=$(secs)
[ "$AFTER_ROWS" = "301" ] \
  && ok "retros.log GREW 300 -> 301 (append-only, no 100-row cap)" \
  || bad "retros.log went 300 -> $AFTER_ROWS — retro-stub truncated it again"
[ "$AFTER_SECS" = "301" ] \
  && ok "retros.md GREW 300 -> 301 sections (no 100-section cap)" \
  || bad "retros.md went 300 -> $AFTER_SECS sections — retro-stub truncated it again"

# The oldest entry must survive: a cap keeps the tail, so counting alone would pass a
# rotate-then-append that silently dropped the head.
grep -q 'proj-1	' "$Z/retros.log" \
  && ok "the OLDEST retro row survives the stub write" \
  || bad "oldest row gone — the head was dropped, which is what a tail-based cap does"

# ---- class guard: no count-based cap anywhere in retro-stub ----------------
# Matches the two shapes the removed code used and the obvious variants, restricted to lines that
# rewrite one of the retro files (a `tail` inside a comment or on an unrelated file is fine).
python3 - "$STUB" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = []
for n, line in enumerate(src.splitlines(), 1):
    code = line.split('#', 1)[0]
    if not code.strip():
        continue
    if re.search(r'\b(tail|head)\s+-n?\s*-?\d+', code) and re.search(r'RETRO_(LOG|MD)', code):
        bad.append((n, line.strip()))
    if re.search(r'c\s*>=\s*\(.*-\s*\d+\)', code):
        bad.append((n, line.strip()))
if bad:
    for n, l in bad:
        print("  ✗ count cap reintroduced at retro-stub:%d: %s" % (n, l[:120]))
    sys.exit(1)
PY
[ $? -eq 0 ] && ok "no count-based cap in retro-stub (class guard)" || bad "count cap reintroduced in retro-stub"

# ---- the marker must report the OBSERVED loss, not the recovered count -----
# append-retro auto-recovers inside the same branch that writes retros-SHRANK-*.txt. It used to
# print the post-recovery row count, so 626 -> 100 -> 628 was filed as "SHRANK: 626 -> 628" — an
# incident that reads like growth, which is why the markers looked harmless for three days.
python3 - "$APPEND" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'echo "retros\.log SHRANK: \$_sg_prev -> \$(\w+) RETRO rows', src)
if not m:
    sys.exit("  ✗ SHRANK marker line not found in append-retro")
if m.group(1) != "_sg_observed":
    sys.exit("  ✗ SHRANK marker prints $%s — must be the pre-recovery $_sg_observed" % m.group(1))
if not re.search(r'_sg_observed=\$_sg_rows', src):
    sys.exit("  ✗ $_sg_observed is never captured before auto-recovery")
if not re.search(r'lost \$\(\(_sg_prev - _sg_observed\)\)', src):
    sys.exit("  ✗ the WARNING line still subtracts the post-recovery count")
PY
[ $? -eq 0 ] && ok "SHRANK marker reports the pre-recovery row count" || bad "SHRANK marker still reports the recovered count"

[ "$fails" -eq 0 ] && echo "PASSED" || echo "FAILED: $fails"
exit $((fails > 0))
