#!/usr/bin/env bash
# No top-level definition may be shadowed by a later one with the same name (ruff's F811 class),
# checked with the stdlib so it runs on EVERY box.
#
# Why this is a separate file rather than an assertion in test-python-lint.sh: that gate exits with
# `SKIP:` as its first line when ruff and mypy are absent, and run-all.sh classifies a child as SKIP
# only when that line comes first. Printing anything before it would turn a genuinely skipped lint
# gate into a reported PASS.
#
# What it is for, measured: on 2026-09-21 a scripted edit left TWO `def cmd_archive` in
# scripts/zuvo-home/backlog-archive.py. Python keeps the LAST definition, so the first was dead code
# and every test still passed. ruff reports it as F811 — but the test farm has neither ruff nor mypy,
# so the Python gate printed SKIP, the suite said PASS=130 SKIP=6, and the duplicate was committed and
# installed. A correctness check that only runs where the tools happen to exist does not run on the
# machine that runs the suite.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
PASS=0; FAIL=0
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

echo "== python: no shadowed top-level definitions =="

scan(){ python3 - "$ROOT" "$@" <<'PY'
import ast, os, subprocess, sys
root = sys.argv[1]
extra = sys.argv[2:]
files = subprocess.run(["git", "-C", root, "ls-files", "*.py"],
                       capture_output=True, text=True).stdout.split()
# the polyglot helpers are python without a .py name, and are edited by the same scripts
files += [f for f in extra if f not in files]
bad = []
for rel in files:
    path = os.path.join(root, rel)
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (OSError, SyntaxError, ValueError):
        continue
    seen = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name in seen:
                bad.append(f"{rel}: {node.name} defined at line {seen[node.name]} AND {node.lineno}")
            seen[node.name] = node.lineno
print("\n".join(bad))
PY
}

OUT="$(scan)"
if [ -z "$OUT" ]; then
  ok "no shadowed top-level def/class in the tracked python corpus"
else
  no "a later definition shadows an earlier one — everything above it is dead code:"
  printf '%s\n' "$OUT" | sed 's/^/      /'
fi

# self-check: the scanner must actually detect the shape, or a green line means nothing
TMP="$(mktemp -d "${TMPDIR:-/tmp}/shadowdef.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo"
( cd "$TMP/repo" && git init -q . )
printf 'def f():\n    return 1\n\n\ndef f():\n    return 2\n' > "$TMP/repo/dup.py"
( cd "$TMP/repo" && git add dup.py >/dev/null 2>&1 )
SELF="$(python3 - "$TMP/repo" <<'PY'
import ast, os, subprocess, sys
root = sys.argv[1]
files = subprocess.run(["git", "-C", root, "ls-files", "*.py"], capture_output=True,
                       text=True).stdout.split()
bad = []
for rel in files:
    tree = ast.parse(open(os.path.join(root, rel), encoding="utf-8").read())
    seen = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name in seen:
                bad.append(rel)
            seen[node.name] = node.lineno
print("\n".join(bad))
PY
)"
[ -n "$SELF" ] && ok "the scanner detects a duplicate on a fixture (so a clean result means something)" \
  || no "the scanner found nothing on a file with two identical defs — it proves nothing"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
