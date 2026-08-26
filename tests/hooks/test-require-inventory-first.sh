#!/usr/bin/env bash
# Contract for require-inventory-first.sh — the PreToolUse hook that catches a NEW spec file being
# written with no frozen inventory behind it.
#
# 30% of benchmark runs wrote tests and produced no manifest at all, which makes them invisible to
# every later layer. But the risk here is the mirror of that: this hook sits in front of every file
# write, so a false block is far more expensive than a missed case. The negative space is therefore
# tested harder than the positive — an existing spec, a repo not using zuvo, a production file, an
# already-inventoried spec, malformed input.
#
# bash 3.2-compatible (macOS default). Accumulate-and-report.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/require-inventory-first.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$HOOK" ] || { bad "hooks/require-inventory-first.sh does not exist"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R/.git" "$R/src" "$R/zuvo/contracts"
printf 'export const alpha = (n) => n + 1;\n' > "$R/src/thing.ts"
printf 'it("old", () => {});\n' > "$R/src/existing.spec.ts"

run_hook() { # run_hook <tool> <file_path>
  python3 - "$1" "$2" "$R" > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "cwd": sys.argv[3]},
          sys.stdout)
PY
  bash "$HOOK" < "$TMP/in.json" 2> "$TMP/err"
}

# ── 1. the measured case: a NEW spec for a file nothing has inventoried ──────
# The repo must already be USING write-tests for this to apply — a manifest for some other file is
# what makes that true. See case 2b for why the directory alone is not enough, and note the honest
# limit that follows: the very first spec in a repo that has never produced a manifest cannot be
# distinguished from a repo that never adopted the protocol, so it passes.
python3 - "$R" <<'PY2'
import json, os, sys
root = sys.argv[1]
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/somewhere-else.ts",
           "stack": "ts", "test_files": ["src/somewhere-else.spec.ts"], "status": "final",
           "symbols": []},
          open(os.path.join(root, "zuvo/contracts/somewhere-else.coverage.json"), "w"), indent=1)
PY2
run_hook Write "$R/src/thing.spec.ts"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'scaffold' "$TMP/err"; then
  pass "a new spec with no inventory is blocked, and the message names the generator"
else
  bad "the measured case was not caught (exit=$rc): $(head -2 "$TMP/err")"
fi
grep -q 'BEFORE the first' "$TMP/err" \
  && pass "the message says why the order matters, in one line" \
  || bad "message does not explain the ordering"

# The printed command must RUN as printed. The first version assumed $ZUVO_BASE was exported; in a
# container where it was not, the agent correctly refused to fake a manifest or disable the hook —
# and then had nowhere to go. A block with an unusable instruction is a dead end, not a gate.
grep -q 'zuvo-base' "$TMP/err" \
  && pass "the command resolves the install root instead of assuming it is exported" \
  || bad "the message hands over a command that only works if ZUVO_BASE is already set"
grep -q 'not installed here' "$TMP/err" \
  && pass "it says what to do when zuvo is not installed at all" \
  || bad "no guidance for the case where the resolver itself is missing"

# ── 2. negative space — each of these must pass through untouched ────────────
# Extending a suite that already exists is not the moment the inventory is frozen. Blocking it is
# what would make this a hook people disable.
run_hook Edit "$R/src/existing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "editing an EXISTING spec is untouched" \
  || bad "blocked an edit to an existing spec (exit=$rc)"

run_hook Write "$R/src/other.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "a production file is none of its business" \
  || bad "blocked a non-spec write (exit=$rc)"

# A repo that does not use zuvo must never see this.
mkdir -p "$TMP/plain/.git/x" "$TMP/plain/src"
python3 - Write "$TMP/plain/src/a.spec.ts" "$TMP/plain" > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "cwd": sys.argv[3]},
          sys.stdout)
PY
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "a repo with no zuvo/contracts is never touched" \
  || bad "blocked in a repo that does not use zuvo (exit=$rc)"

# ── 2b. a directory of refactor contracts is not adoption of THIS protocol ───
# A contracts directory holding ONLY refactor contracts is not evidence that write-tests is in use.
# Measured across the fleet: 1,033 refactor contracts against 26 coverage manifests, and only 5 of
# 57 repos carry a single manifest. Keying on the directory alone would block every new test file in
# 52 repos that never adopted this protocol — a wall, not a speed bump.
mkdir -p "$TMP/refonly/.git" "$TMP/refonly/src" "$TMP/refonly/zuvo/contracts"
printf '{"version":5,"stage":"COMPLETE","file":"src/x.ts"}\n' \
  > "$TMP/refonly/zuvo/contracts/refactor-abc12345.json"
python3 - Write "$TMP/refonly/src/new.spec.ts" "$TMP/refonly" > "$TMP/in.json" <<'PY2'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "cwd": sys.argv[3]},
          sys.stdout)
PY2
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a repo with only REFACTOR contracts is not conscripted into this protocol" \
  || bad "blocked in a repo that never adopted write-tests (exit=$rc)"

# ── 3. an inventoried spec passes, by either route ───────────────────────────
python3 - "$R" <<'PY'
import json, os, sys
root = sys.argv[1]
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/thing.ts",
           "stack": "ts", "test_files": ["src/thing.spec.ts"], "status": "inventory",
           "symbols": []},
          open(os.path.join(root, "zuvo/contracts/thing.coverage.json"), "w"), indent=1)
PY
run_hook Write "$R/src/thing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "a spec the manifest DECLARES passes" \
  || bad "blocked an inventoried spec (exit=$rc)"

# The manifest names the production file but predicted a different spec name — a split suite. The
# work IS inventoried, so this must not block.
run_hook Write "$R/src/thing.parsing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "a split part of an inventoried production file passes" \
  || bad "blocked a split spec whose production file is inventoried (exit=$rc)"

# A spec for something genuinely uninventoried still blocks.
run_hook Write "$R/src/unrelated-module.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "a spec for an uninventoried file still blocks" \
  || bad "an uninventoried spec slipped through (exit=$rc)"

# ── 3d. a RELATIVE file_path resolves against the AGENT's cwd ────────────────
# Cross-model review finding, and the expensive kind: os.path.exists() on a relative path checks
# the HOOK's process directory, not the agent's. An existing spec then looks new, no manifest covers
# it, and an ordinary edit to a file that has existed for months is refused.
python3 - Edit "src/existing.spec.ts" "$R" > "$TMP/in.json" <<'PY2'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "cwd": sys.argv[3]},
          sys.stdout)
PY2
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] \
  && pass "a relative path to an EXISTING spec is recognised as existing" \
  || bad "a relative path was resolved against the hook's own directory (exit=$rc)"

# ── 3e. the production stem is matched, not a substring of it ────────────────
# `"a" in "main.py"` is true, so a new `a_test.py` was waved through by a manifest for ANY file
# whose name contains an "a" — which is most of them.
python3 - "$R" <<'PY2'
import json, os, sys
root = sys.argv[1]
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/main.py",
           "stack": "python", "test_files": ["tests/test_main.py"], "status": "final",
           "symbols": []},
          open(os.path.join(root, "zuvo/contracts/main.coverage.json"), "w"), indent=1)
PY2
run_hook Write "$R/src/a_test.py"; rc=$?
[ "$rc" -eq 2 ] \
  && pass "a one-letter stem does not match every manifest by substring" \
  || bad "substring matching let an unrelated spec through (exit=$rc)"
rm -f "$R/zuvo/contracts/main.coverage.json"

# ── 3f. a MISSING cwd must not silently become the hook's own directory ──────
# Second-reviewer finding. Falling back to os.getcwd() means a payload without `cwd` is resolved
# against wherever the hook happens to run, so an existing spec looks absent and an ordinary edit is
# refused.
python3 - Edit "src/existing.spec.ts" > "$TMP/in.json" <<'PY2'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}}, sys.stdout)
PY2
( cd "$R" && bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && pass "a payload with no cwd still finds an existing spec" \
  || bad "a missing cwd was resolved against the hook's directory (exit=$rc)"

# ── 3g. a repo-root-relative path from a package cwd ─────────────────────────
# The command may run inside a package while the path is written relative to the repository. Only
# trying the payload's cwd blocks an edit to a file that is plainly there.
mkdir -p "$R/pkg2"
python3 - Edit "src/existing.spec.ts" "$R/pkg2" > "$TMP/in.json" <<'PY2'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "cwd": sys.argv[3]},
          sys.stdout)
PY2
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "a repo-root-relative path resolves from a package cwd" \
  || bad "only the payload cwd was tried, so an existing spec looked absent (exit=$rc)"

# ── 3h. the message names the directory the hook actually READ ───────────────
# With ZUVO_OUTPUT_DIR set, telling the agent to scaffold into the default zuvo/contracts/ sends it
# somewhere this check never looks: it follows the instruction, the manifest lands elsewhere, and
# the write is refused again. An instruction that cannot satisfy the gate it came from is an
# infinite loop with a helpful tone.
mkdir -p "$R/custom-out/contracts"
cp "$R/zuvo/contracts/somewhere-else.coverage.json" "$R/custom-out/contracts/" 2>/dev/null
python3 - Write "$R/src/fresh-one.spec.ts" "$R" > "$TMP/in.json" <<'PY2'
import json, sys
json.dump({"tool_name": sys.argv[1], "tool_input": {"file_path": sys.argv[2]}, "cwd": sys.argv[3]},
          sys.stdout)
PY2
ZUVO_OUTPUT_DIR="$R/custom-out" bash "$HOOK" < "$TMP/in.json" 2> "$TMP/err"; rc=$?
if [ "$rc" -eq 2 ]; then
  grep -q 'custom-out/contracts' "$TMP/err" \
    && pass "the message points at the directory the hook read, not the default" \
    || bad "the message sends the agent to a path the check never looks at: $(grep -o -- '--out [^ ]*' "$TMP/err")"
else
  bad "the custom output dir was not honoured at all (exit=$rc)"
fi

# ── 4. escape and fail-open ──────────────────────────────────────────────────
ZUVO_ALLOW_UNTRACKED_TESTS=1 run_hook Write "$R/src/escape.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "the human escape hatch works" || bad "escape ignored (exit=$rc)"

printf 'not json' > "$TMP/in.json"
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "malformed input fails OPEN" || bad "malformed input blocked (exit=$rc)"

: > "$TMP/in.json"
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "empty input fails OPEN" || bad "empty input blocked (exit=$rc)"

printf 'garbage\n' > "$R/zuvo/contracts/broken.coverage.json"
run_hook Write "$R/src/another-new.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "an unreadable manifest is skipped, not treated as coverage" \
  || bad "a garbage manifest was read as inventory (exit=$rc)"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
