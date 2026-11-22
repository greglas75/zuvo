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

echo "=== --lang (D6: root pyproject.toml must not decide the language of a TypeScript change) ==="
mkdir -p "$TMP/lang"
printf '[project]\nname="x"\n' > "$TMP/lang/pyproject.toml"
groups_of() { # groups_of <project> [lang] -> matched stack keys, sorted
  python3 - "$CP" "$1" "${2:-}" <<'PY'
import importlib.machinery, importlib.util, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("compute_preload", sys.argv[1])
spec = importlib.util.spec_from_loader("compute_preload", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sig = m.collect_signals(Path(sys.argv[2]))
if sys.argv[3]:
    m.apply_lang(sig, sys.argv[3])
by = {"typescript": ["a"], "python": ["b"], "php": ["c"]}
print(",".join(sorted(k for k, _, _ in m.match_groups(by, sig))))
PY
}
[ "$(groups_of "$TMP/lang")" = "python" ] && ok "control: without --lang a root pyproject.toml selects python" || bad "control: got [$(groups_of "$TMP/lang")]"
[ "$(groups_of "$TMP/lang" ts)" = "typescript" ] && ok "--lang ts selects typescript and suppresses the python manifest rule" || bad "--lang ts: got [$(groups_of "$TMP/lang" ts)]"

# A forced language must also beat the dependency rule: typescript in a root devDependencies made
# `--lang py` load the TypeScript group as well. Mixed-language changes name both (--lang ts,py).
mkdir -p "$TMP/lang2"
printf '[project]\nname="x"\n' > "$TMP/lang2/pyproject.toml"
printf '{"devDependencies":{"typescript":"5"}}\n' > "$TMP/lang2/package.json"
[ "$(groups_of "$TMP/lang2" py)" = "python" ] && ok "--lang py ignores a root typescript devDependency" || bad "--lang py: got [$(groups_of "$TMP/lang2" py)]"
[ "$(groups_of "$TMP/lang2" ts,py)" = "python,typescript" ] && ok "--lang ts,py selects both language groups" || bad "--lang ts,py: got [$(groups_of "$TMP/lang2" ts,py)]"
# the public CLI refuses a --lang with no value instead of reading it as the project path
out="$(python3 "$CP" review --lang 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--lang needs a value' && ok "--lang without a value is refused with its own message" || bad "--lang without a value: rc=$rc [$out]"
# an unknown value would force the language, match no group and preload no language tools without a word
out="$(python3 "$CP" review "$TMP/lang2" --lang tsx 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not a known language' && ok "--lang tsx is refused (it would silently drop every language group)" || bad "--lang tsx: rc=$rc [$out]"
# repeated --lang merges (the last one used to win and silently dropped a language of a mixed change)
out="$(python3 "$CP" review "$TMP/lang2" --lang ts --lang py 2>&1)"
printf '%s' "$out" | grep -q 'typescript (rule #1' && printf '%s' "$out" | grep -q 'python (rule #1' && ok "repeated --lang flags keep both languages" || bad "repeated --lang: [$out]"
# a framework/test-runner/driver rule must not re-admit another language's group once --lang is forced
printf '{"devDependencies":{"typescript":"5","jest":"29"}}\n' > "$TMP/lang2/package.json"
[ "$(groups_of "$TMP/lang2" py)" = "python" ] && ok "--lang py ignores a root typescript dependency under every later rule" || bad "--lang py with jest: got [$(groups_of "$TMP/lang2" py)]"
# D6 follow-up: ts + py both list resolve_constant_value; the preload loads it once, so the expected count
# is the emitted union, not the sum (the math gate aborted a valid mixed-language review by one)
out="$(python3 "$CP" review "$ROOT" --lang ts,py 2>&1)"
exp="$(printf '%s\n' "$out" | sed -n 's/^\[Expected after load\] tools=\([0-9]*\).*/\1/p')"
n="$(printf '%s\n' "$out" | sed -n 's/^ToolSearch(query="select:\(.*\)")$/\1/p' | tail -1 | tr ',' '\n' | grep -c .)"
[ -n "$exp" ] && [ "$exp" = "$n" ] && ok "expected_tools ($exp) equals the number of tools in the emitted select: query" || bad "expected=$exp emitted=$n"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
