#!/usr/bin/env bash
# test-backlog-table-row-boundary.sh — a flush-left backlog table row ("| B-1553 | OPEN | …") ends the block of
# the bullet/checkbox entry above it, even past a blank line, and the table's header goes with the table.
#
# The defect: writers append `| B-NNNN |` rows at the end of the file, and entry_block counted them as the last
# checkbox's continuation — the parser admits the same line as an entry of its own, so archive/drop-stale of that
# checkbox moved or quoted foreign entries with it (tgm-survey-platform: one bullet carried 6846 table rows).
# What must NOT change: an entry's own id-less content table, an indented table, a table under a heading entry,
# and table-shaped text inside a fence all stay inside the block.
#
# Level: medium — the real modules and CLI on fixture files in a temp directory; no network, no sleep.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOME_PY="$ROOT/scripts/zuvo-home"
PASS=0; FAIL=0
ok() { echo "  PASS $1"; PASS=$((PASS + 1)); }
no() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }
FIX="$(mktemp -d "${TMPDIR:-/tmp}/backlog-table-row.XXXXXX")" && FIX="$(cd "$FIX" && pwd -P)" \
  && [ -n "$FIX" ] || { echo "FATAL: no fixture directory" >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

echo "== entry_block: where a bullet entry ends (named cases) =="
# Each case: the document, and the expected block length (lines) of the entry on its first line.
got="$(python3 - "$HOME_PY" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from zuvo_backlog_block import entry_block
ROW = "| B-1553 | OPEN | scripts/ci/e2e-shards.test.mjs | test-oracle | medium |\n"
CASES = {
    "id row right under a checkbox ends it": ("- [ ] **B-A** the entry\n" + ROW, 1),
    "id row after a blank line ends it": ("- [ ] **B-A** the entry\n\n" + ROW, 1),
    "header and separator go with the table": (
        "- [ ] **B-A** the entry\n  continuation\n\n| ID | Status | File |\n|----|--------|------|\n" + ROW, 2),
    "an indented id row is the entry's content": ("- [ ] **B-A** the entry\n  " + ROW, 2),
    "an id-less content table stays, and the block runs past it": (
        "- [ ] **B-A** the entry\n| Lead | Verdict |\n|---|---|\n| cache | fixed |\nafter the table\n", 5),
    "a plain bullet ends at an id row too": ("- a note without an id\n" + ROW, 1),
    "table text inside a fence is content": ("- [ ] **B-A** the entry\n```\n" + ROW + "```\n", 4),
    "a template row is not an entry, so it stays content": ("- [ ] **B-A** the entry\n| B-NNN | <file> | <problem> |\n", 2),
    "the last table row does not own the prose after the table": (ROW + "a section note after the table\n", 1),
    "a header, separator and template row go with the table": (
        "- [ ] **B-A** the entry\n| ID | File |\n|----|------|\n| B-NNN | <file> |\n" + ROW, 1),
    "an id row glued under a header-less content row splits off at the id row": (
        "- [ ] **B-A** the entry\n| cache | fixed |\n" + ROW, 2),
    "an id row glued under a content table splits off, the content table stays": (
        "- [ ] **B-A** the entry\n| Lead | Verdict |\n|---|---|\n| cache | fixed |\n" + ROW, 4),
}
for name, (doc, want) in CASES.items():
    lines = doc.splitlines(keepends=True)
    print(f"{entry_block(lines, 0) == want}|{name}|got {entry_block(lines, 0)} want {want}")
PY
)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$got" | grep -c '|')" -eq 12 ] \
  || no "the case runner crashed or ran short (rc=$rc): $got"
while IFS='|' read -r verdict name detail; do
  [ "$verdict" = True ] && ok "$name" || no "$name ($detail)"
done <<< "$got"

echo "== the boundaries next to the new rule =="
got="$(python3 - "$HOME_PY" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from zuvo_backlog_block import entry_block
print(entry_block("- [ ] **B-A** one\n-[ ] B-b a sibling written without the space\n".splitlines(keepends=True), 0))
try:
    entry_block(["- [ ] **B-A** one\n"], 1)
except IndexError as exc:
    print("IndexError:", exc)
try:
    entry_block([], 0)
except IndexError as exc:
    print("IndexError:", exc)
PY
)"
[ "$(printf '%s\n' "$got" | sed -n 1p)" = 1 ] && ok "a no-space '-[ ] B-b' sibling still ends the block" || no "no-space sibling: $got"
[ "$(printf '%s\n' "$got" | sed -n 2p)" = "IndexError: entry_block: start 1 outside 0..0 (1 line(s)) — the caller's line number does not match this text" ] \
  && ok "an out-of-range start raises IndexError naming the index and the length" || no "out-of-range start: $got"
[ "$(printf '%s\n' "$got" | sed -n 3p)" = "IndexError: entry_block: start 0 outside 0..-1 (0 line(s)) — the caller's line number does not match this text" ] \
  && ok "an empty document raises IndexError too" || no "empty document: $got"

# Invariant over generated documents (seed recorded): no flush-left table ENTRY row is ever inside a bullet's
# block, and a table entry's block is its own row.
got="$(python3 - "$HOME_PY" <<'PY'
import random, sys; sys.path.insert(0, sys.argv[1])
import zuvo_backlog_parse as zb
from zuvo_backlog_block import entry_block
seed = 20261010; rnd = random.Random(seed); bad = []
PARTS = ["  continuation\n", "\n", "| Lead | Verdict |\n", "|---|---|\n", "| cache | fixed |\n",
         "| B-17 | OPEN | src/a.ts | x |\n", "| B-NNN | <file> |\n", "  | B-18 | OPEN | nested |\n", "prose\n"]
for _ in range(3000):
    lines = ["- [ ] **B-A** the entry\n"] + [rnd.choice(PARTS) for _ in range(rnd.randint(0, 8))]
    end = entry_block(lines, 0)
    if any(ln.startswith("|") and zb.is_table_entry(ln.strip()) for ln in lines[1:end]):
        bad.append("".join(lines))
    for k, ln in enumerate(lines):
        if ln.startswith("|") and zb.is_table_entry(ln.strip()) and entry_block(lines, k) != k + 1:
            bad.append("".join(lines))
print("seed=%d mismatches=%d" % (seed, len(bad)))
PY
)"
[ "$got" = "seed=20261010 mismatches=0" ] && ok "boundary invariant holds on 3000 generated documents ($got)" || no "boundary invariant: $got"

echo "== a heading entry keeps its table =="
got="$(python3 - "$HOME_PY" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from zuvo_backlog_block import entry_block
doc = "## B-HEAD the heading entry\n\n| ID | Status |\n|----|--------|\n| B-1 | OPEN |\n\n## next\n"
print(entry_block(doc.splitlines(keepends=True), 0))
PY
)"
[ "$got" = 5 ] && ok "a heading entry's block still holds its id table (5 lines)" || no "heading entry block: $got"

echo "== archive moves the checkbox, never the table row under it =="
R="$FIX/repo"; mkdir -p "$R/memory"
printf '# Tech Debt Backlog\n\n## Open\n\n- [x] **B-DONE** [FIXED deadbee] src/a.ts the closed entry\n| B-1553 | OPEN | scripts/ci/e2e-shards.test.mjs | test-oracle | medium |\n' > "$R/memory/backlog.md"
out="$(python3 "$HOME_PY/backlog-archive.py" archive --repo "$R" 2>&1)"; rc=$?
want="$(printf '# Tech Debt Backlog\n\n## Open\n\n| B-1553 | OPEN | scripts/ci/e2e-shards.test.mjs | test-oracle | medium |')"
{ [ "$rc" -eq 0 ] && [ "$(cat "$R/memory/backlog.md")" = "$want" ] \
  && ! grep -q 'B-1553' "$R/memory/backlog-done.md" && grep -q 'B-DONE' "$R/memory/backlog-done.md"; } \
  && ok "the ticked checkbox is archived and the B-1553 row stays open in backlog.md" \
  || no "archive: rc=$rc '$out' | open: $(grep -c B-1553 "$R/memory/backlog.md") done: $(grep -c B-1553 "$R/memory/backlog-done.md" 2>/dev/null)"

printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
