#!/usr/bin/env bash
# Write zuvo's marker-delimited blocks into ~/.codex/AGENTS.md (idempotent).
#
# WHY THIS EXISTS. Two rules that keep this workstation usable — the 300000 ms poll ceiling and
# "when the farm is busy, WAIT" — lived ONLY as hand-injected text in ~/.codex/AGENTS.md. Nothing
# in the repo knew about them, so they were one machine rebuild away from silently vanishing, and
# a drafting error in one of them could not be caught by any test. That error happened: the
# no-local-fallback block told agents to "re-queue once, or report BLOCKED_FARM_BUSY and stop",
# and on 2026-09-03 an agent obeyed it literally — two attempts, then it abandoned a finished
# branch (no push, no PR, no merge) over a farm that would simply have queued the run.
#
# AGENTS.md is the USER'S file. Only the regions between our own markers are ever touched; the
# rest is copied through byte-for-byte, and a block that is absent is appended at the end.
set -uo pipefail

SRC_DIR="${1:-}"
TARGET="${2:-$HOME/.codex/AGENTS.md}"
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || { echo "  agents-md: no source dir — skipped" >&2; exit 0; }

mkdir -p "$(dirname "$TARGET")" 2>/dev/null || true
[ -f "$TARGET" ] || : > "$TARGET"

SRC_DIR="$SRC_DIR" TARGET="$TARGET" python3 - <<'PY'
import os, re, sys

src_dir = os.environ["SRC_DIR"]
target  = os.environ["TARGET"]

try:
    doc = open(target, errors="replace").read()
except OSError as exc:
    print("  agents-md: cannot read %s (%s) — skipped" % (target, exc), file=sys.stderr)
    raise SystemExit(0)

changed = []
for fn in sorted(os.listdir(src_dir)):
    if not fn.endswith(".md"):
        continue
    block = open(os.path.join(src_dir, fn), errors="replace").read().strip()
    m = re.match(r"<!-- (zuvo:[a-z0-9-]+) -->", block)
    if not m:
        print("  agents-md: %s has no opening marker — skipped" % fn, file=sys.stderr)
        continue
    name = m.group(1)
    close = "<!-- /%s -->" % name
    if not block.rstrip().endswith(close):
        print("  agents-md: %s is not closed by %s — skipped" % (fn, close), file=sys.stderr)
        continue
    pat = re.compile(r"<!-- %s -->.*?%s" % (re.escape(name), re.escape(close)), re.S)
    # re.sub would read backslashes and \g<...> in the REPLACEMENT as references. These blocks are
    # prose full of backticks and paths today, but one regex example in them would corrupt the
    # user's file — so substitute with a function, which takes the string literally.
    if pat.search(doc):
        new = pat.sub(lambda _m: block, doc, count=1)
    else:
        new = doc.rstrip("\n") + "\n\n" + block + "\n"
    if new != doc:
        doc = new
        changed.append(name)

if changed:
    tmp = target + ".zuvo-tmp.%d" % os.getpid()
    with open(tmp, "w") as fh:
        fh.write(doc)
    os.replace(tmp, target)   # atomic: a half-written AGENTS.md is a broken instruction file
    print("  agents-md: updated %s" % ", ".join(changed))
else:
    print("  agents-md: already current")
PY
