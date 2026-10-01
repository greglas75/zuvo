#!/usr/bin/env bash
# Tests scripts/zuvo-home/compute-preload — the dependency signal read from package.json files.
#
# `dependencies` / `devDependencies` are objects keyed by package name. A file where one of them is a
# list or a string is not a package.json npm would accept, and its elements are not package names:
# iterating it put list items (or single characters of a string) into the deps set, where they could
# match a framework rule. Only an object contributes names; a package.json whose top level is not an
# object contributes nothing and does not crash the trace.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CP="$ROOT/scripts/zuvo-home/compute-preload"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

deps_of() { # deps_of <project-dir> -> the sorted deps set, one per line (or ERROR:<type>)
  python3 - "$CP" "$1" <<'PY'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("compute_preload", sys.argv[1])
spec = importlib.util.spec_from_loader("compute_preload", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
try:
    print("\n".join(sorted(m.collect_signals(Path(sys.argv[2]))["deps"])))
except Exception as e:  # the test reports the crash by type instead of dying with a traceback
    print("ERROR:" + type(e).__name__)
PY
}

echo "=== object sections ==="
mkdir -p "$TMP/obj"
# Two keys per section: every key is a name, not only the first.
printf '{"dependencies":{"react":"^19","next":"^16"},"devDependencies":{"vitest":"^4","jest":"^30"}}\n' > "$TMP/obj/package.json"
got="$(deps_of "$TMP/obj")"
[ "$got" = "$(printf 'jest\nnext\nreact\nvitest')" ] && ok "object sections give all their keys" || bad "object sections: got [$got]"

echo "=== a list section ==="
mkdir -p "$TMP/list"
printf '{"dependencies":["next","react"],"devDependencies":{"vitest":"^4"}}\n' > "$TMP/list/package.json"
got="$(deps_of "$TMP/list")"
[ "$got" = "vitest" ] && ok "a list section contributes no names" || bad "a list section: got [$got]"

echo "=== a string section ==="
mkdir -p "$TMP/str"
printf '{"dependencies":"jest"}\n' > "$TMP/str/package.json"
got="$(deps_of "$TMP/str")"
[ -z "$got" ] && ok "a string section contributes no names (no single characters)" || bad "a string section: got [$got]"

echo "=== a non-object top level ==="
mkdir -p "$TMP/top"
printf '["react"]\n' > "$TMP/top/package.json"
got="$(deps_of "$TMP/top")"
[ -z "$got" ] && ok "a list package.json contributes nothing and does not crash" || bad "a list package.json: got [$got]"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
