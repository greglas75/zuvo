#!/usr/bin/env bash
# Contract for route-suite-through-verify.sh — the PreToolUse hook that sends a hand-run test
# command through the instrument.
#
# The hook exists because of a measurement, and its RISK is the mirror of that measurement: a hook
# that blocks test commands it should not is worse than one that misses cases. So the negative
# space is tested harder than the positive: no manifest, unrelated spec, already-measured receipt,
# the instrument's own invocation, malformed input, missing tools — every one of those must pass
# through untouched.
#
# bash 3.2-compatible (macOS default). Accumulate-and-report.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/route-suite-through-verify.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$HOOK" ] || { bad "hooks/route-suite-through-verify.sh does not exist"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── fixture: a repo with a manifest that declares one spec ────────────────────
R="$TMP/repo"
mkdir -p "$R/.git" "$R/src" "$R/zuvo/contracts"
printf 'export const alpha = (n) => n + 1;\n' > "$R/src/thing.ts"
printf 'it("works", () => {});\n' > "$R/src/thing.spec.ts"
printf 'it("other", () => {});\n' > "$R/src/unrelated.spec.ts"

write_manifest() { # write_manifest <receipt-python-or-empty>
  mkdir -p "$R/zuvo/contracts"
  python3 - "$R" "$1" <<'PY'
import hashlib, json, os, sys
root, mutation = sys.argv[1], sys.argv[2]
spec = os.path.join(root, "src/thing.spec.ts")
m = {"schema": "zuvo-coverage-manifest/v1", "production_file": "src/thing.ts",
     "stack": "ts", "test_files": ["src/thing.spec.ts"], "status": "final", "symbols": []}
if mutation == "fresh":
    m["verification"] = {"schema": "zuvo-verify/v1", "epoch": 1, "spec_sha256": {
        "src/thing.spec.ts": hashlib.sha256(open(spec, "rb").read()).hexdigest()}}
elif mutation == "stale":
    m["verification"] = {"schema": "zuvo-verify/v1", "epoch": 1,
                         "spec_sha256": {"src/thing.spec.ts": "0" * 64}}
json.dump(m, open(os.path.join(root, "zuvo/contracts/thing.coverage.json"), "w"), indent=1)
PY
}

run_hook() { # run_hook <command> ; returns the hook's exit code, stderr in $TMP/err
  python3 - "$1" "$R" > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]},
          sys.stdout)
PY
  bash "$HOOK" < "$TMP/in.json" 2> "$TMP/err"
}

# ── 1. the measured case: a bare runner on a declared, unmeasured spec ────────
write_manifest ""
run_hook "npx vitest run src/thing.spec.ts"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'verify-tests --manifest' "$TMP/err"; then
  pass "a bare runner on a tracked, unmeasured spec is routed to the instrument"
else
  bad "the measured case was not routed (exit=$rc): $(head -2 "$TMP/err")"
fi

# The message has to name the manifest, or the agent has to guess the argument.
grep -q 'zuvo/contracts/thing.coverage.json' "$TMP/err" \
  && pass "the message names the manifest to pass" \
  || bad "message does not name the manifest"

# ── 2. already measured, in its current state → no interference ───────────────
write_manifest fresh
run_hook "npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "a spec already measured as it stands runs freely" \
  || bad "blocked a spec that carries a current receipt (exit=$rc)"

# ── 3. receipt stale for THIS spec → routed again ─────────────────────────────
write_manifest stale
run_hook "npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "a receipt that no longer matches the spec routes again" \
  || bad "a stale receipt was treated as coverage (exit=$rc)"

# ── 3b. the shapes agents ACTUALLY use ───────────────────────────────────────
# The first version of the pattern missed the exact command the benchmark caught it on:
#
#   cd apps/designer
#   timeout 100 node --max-old-space-size=8192 ./node_modules/vitest/vitest.mjs run <spec>
#
# — separated by a NEWLINE rather than `;&|`, and reaching the runner through a path rather than
# through npx. A memory flag and a `cd` are what you write when the suite is big enough to need
# tests at all, so this is the normal shape, not an edge case.
write_manifest ""
run_hook "cd $R/src
timeout 100 node --max-old-space-size=8192 ./node_modules/vitest/vitest.mjs run $R/src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "a newline-separated, path-reached runner is caught" \
  || bad "the shape measured on the rig still slips through (exit=$rc)"

run_hook "./node_modules/.bin/vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "a .bin/ shim is caught" || bad "missed ./node_modules/.bin/ (exit=$rc)"

run_hook "pnpm exec vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "pnpm exec is caught" || bad "missed pnpm exec (exit=$rc)"

# A `cd` inside the command decides what the spec path means. Measured on the rig, third variant of
# the same root mistake — resolving a path against the wrong base:
#
#   cd <repo>/apps/api && npx vitest run src/modules/runner/x.spec.ts
#
# In a monorepo the cd is not optional; it is how you reach the package that owns the config.
mkdir -p "$R/pkg/src"
printf 'it("pkg", () => {});\n' > "$R/pkg/src/inner.spec.ts"
python3 - "$R" <<'PY2'
import json, os, sys
root = sys.argv[1]
p = os.path.join(root, "zuvo/contracts/inner.coverage.json")
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/thing.ts", "stack": "ts",
           "test_files": ["pkg/src/inner.spec.ts"], "status": "final", "symbols": []},
          open(p, "w"), indent=1)
PY2
run_hook "cd $R/pkg && npx vitest run src/inner.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "a spec path relative to a cd inside the command is resolved" \
  || bad "the cd was ignored, so the path resolved to nothing (exit=$rc)"
rm -f "$R/zuvo/contracts/inner.coverage.json"

# ── 3c. the escape is not typable by the thing being blocked ─────────────────
# Measured on the rig: an agent read this hook in its own home directory, learned the name of the
# escape variable from it, and typed it inline into the command it was already trying to run:
#
#   cd <repo> && ZUVO_ALLOW_BARE_TESTS=1 npx vitest run <spec>
#
# An inline assignment applies to the command the hook is inspecting; the hook itself runs in the
# harness's environment and never sees it. So this must still block — and it must block because
# the prefix is stripped before matching, not because a wildcard happens to absorb it. Same class
# as `--reset-budget` and `--budget 999`: an escape an agent can type is not an escape, it is a
# feature request from the thing being measured.
write_manifest ""
run_hook "cd $R && ZUVO_ALLOW_BARE_TESTS=1 npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "an inline ZUVO_ALLOW_BARE_TESTS=1 does not buy a bare run" \
  || bad "an agent-typed inline escape got through (exit=$rc)"

run_hook "ZUVO_ALLOW_BARE_TESTS=1 npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "the same prefix with no cd is stripped too" \
  || bad "a leading assignment hid the runner (exit=$rc)"

run_hook "env ZUVO_ALLOW_BARE_TESTS=1 npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "an 'env VAR=1' prefix is stripped too" \
  || bad "env-prefixed escape got through (exit=$rc)"

# Stripping the prefix must not turn a NON-invocation into one.
run_hook "FOO=vitest echo not a run of src/thing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "an assignment whose VALUE is a runner name is not an invocation" \
  || bad "blocked on an assignment value rather than a call (exit=$rc)"

# And the notice must not teach the variable to the agent it just blocked. The escape belongs to
# whoever installed the hook; they can read it in the file.
run_hook "npx vitest run src/thing.spec.ts" >/dev/null 2>&1
grep -q 'ZUVO_ALLOW_BARE_TESTS' "$TMP/err" \
  && bad "the block notice names its own escape hatch — that is where the agent learned it" \
  || pass "the notice does not name the escape variable"

# ── 4. negative space — every one of these must pass through ──────────────────
write_manifest ""

run_hook "npx vitest run src/unrelated.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "a spec no manifest declares is none of its business" \
  || bad "blocked an unrelated spec (exit=$rc)"

run_hook "~/.zuvo/verify-tests --manifest zuvo/contracts/thing.coverage.json"; rc=$?
[ "$rc" -eq 0 ] && pass "the instrument's own invocation is never blocked" \
  || bad "the hook blocked the tool it redirects to — that is a loop with no exit (exit=$rc)"

run_hook "npx vitest"; rc=$?
[ "$rc" -eq 0 ] && pass "a whole-suite run naming no spec passes through" \
  || bad "blocked a bare suite run (exit=$rc)"

run_hook "git status"; rc=$?
[ "$rc" -eq 0 ] && pass "a non-test command passes through" || bad "blocked git status (exit=$rc)"

run_hook "echo vitest is a test runner"; rc=$?
[ "$rc" -eq 0 ] && pass "the word 'vitest' in prose is not an invocation" \
  || bad "blocked on a mention rather than a call (exit=$rc)"

rm -rf "$R/zuvo"
run_hook "npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "no zuvo contracts directory → no interference at all" \
  || bad "blocked in a repo with no manifests (exit=$rc)"
write_manifest ""

ZUVO_ALLOW_BARE_TESTS=1 run_hook "npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "the human escape hatch works" || bad "escape hatch ignored (exit=$rc)"

# ── 4b. the message must not read as an injection attempt ────────────────────
# Tested end-to-end in a container: the first version explained WHY, quoted a benchmark statistic
# and offered the escape hatch persuasively. The agent refused it as "a classic injection pattern
# — a tool/hook result trying to redirect my next action ... to pressure compliance", and reported
# the block instead of complying. It was right to. So the message states the policy and the
# command, and argues for neither.
write_manifest ""
run_hook "npx vitest run src/thing.spec.ts" >/dev/null 2>&1
if grep -qiE "measured on the benchmark|only tells you|use the instrument instead|if you really need" "$TMP/err"; then
  bad "the message argues its case — that is the shape of an injection, and agents refuse it"
else
  pass "the message states the policy without arguing for it"
fi
[ "$(wc -l < "$TMP/err")" -le 5 ] \
  && pass "the message is short enough to read as a system notice ($(wc -l < "$TMP/err") lines)" \
  || bad "message is $(wc -l < "$TMP/err") lines — long enough to read as persuasion"
grep -q 'verify-tests --manifest' "$TMP/err" \
  && pass "it still carries the exact command to run" \
  || bad "the required command is missing from the notice"

# ── 4c. the runner name in PROSE is not an invocation ────────────────────────
# Found by a cross-model review: the old pattern let any words precede the runner, so a commit
# message mentioning a spec matched and the COMMIT was blocked. A false block on an unrelated
# command is the most expensive thing this hook can do, and in a repo whose subject is test runners
# such prose is not rare.
write_manifest ""
run_hook "git commit -m 'fix vitest run src/thing.spec.ts flakiness'"; rc=$?
[ "$rc" -eq 0 ] && pass "a commit message naming a runner and a tracked spec is not blocked" \
  || bad "blocked a git commit because its MESSAGE mentioned vitest (exit=$rc)"

run_hook "echo 'to reproduce: npx vitest run src/thing.spec.ts'"; rc=$?
[ "$rc" -eq 0 ] && pass "an echo describing the command is not the command" \
  || bad "blocked an echo (exit=$rc)"

# ── 4d. chained cd accumulates ───────────────────────────────────────────────
# `cd a && cd b` lands in a/b. Resolving each target against the original cwd misses the directory
# the command actually runs in, and the spec then looks absent — passing a command this exists for.
mkdir -p "$R/deep/inner"
printf 'it("deep", () => {});\n' > "$R/deep/inner/nested.spec.ts"
python3 - "$R" <<'PY2'
import json, os, sys
root = sys.argv[1]
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/thing.ts", "stack": "ts",
           "test_files": ["deep/inner/nested.spec.ts"], "status": "final", "symbols": []},
          open(os.path.join(root, "zuvo/contracts/nested.coverage.json"), "w"), indent=1)
PY2
run_hook "cd $R/deep && cd inner && npx vitest run nested.spec.ts"; rc=$?
[ "$rc" -eq 2 ] && pass "chained cd targets accumulate" \
  || bad "each cd was resolved against the original cwd, so the spec looked absent (exit=$rc)"
rm -f "$R/zuvo/contracts/nested.coverage.json"

# ── 4e. a quoted path with spaces survives tokenisation ──────────────────────
mkdir -p "$R/My Tests"
printf 'it("spaced", () => {});\n' > "$R/My Tests/spaced.spec.ts"
python3 - "$R" <<'PY2'
import json, os, sys
root = sys.argv[1]
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/thing.ts", "stack": "ts",
           "test_files": ["My Tests/spaced.spec.ts"], "status": "final", "symbols": []},
          open(os.path.join(root, "zuvo/contracts/spaced.coverage.json"), "w"), indent=1)
PY2
run_hook "npx vitest run \"My Tests/spaced.spec.ts\""; rc=$?
[ "$rc" -eq 2 ] && pass "a quoted path containing a space is still matched" \
  || bad "splitting on whitespace lost the path, so the run passed (exit=$rc)"
rm -f "$R/zuvo/contracts/spaced.coverage.json"

# ── 5. fail-open on anything it cannot understand ─────────────────────────────
printf 'not json at all' > "$TMP/in.json"
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "malformed input fails OPEN" || bad "malformed input blocked (exit=$rc)"

: > "$TMP/in.json"
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "empty input fails OPEN" || bad "empty input blocked (exit=$rc)"

python3 - > "$TMP/in.json" <<'PY'
import json, sys
json.dump({"tool_name": "Write", "tool_input": {"file_path": "x.spec.ts"}}, sys.stdout)
PY
bash "$HOOK" < "$TMP/in.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "a non-Bash tool call is ignored" || bad "blocked a Write call (exit=$rc)"

# An unreadable manifest must not become a block: the hook's job is routing, not validation.
printf 'this is not json\n' > "$R/zuvo/contracts/thing.coverage.json"
run_hook "npx vitest run src/thing.spec.ts"; rc=$?
[ "$rc" -eq 0 ] && pass "an unparseable manifest fails OPEN" \
  || bad "an unreadable manifest caused a block (exit=$rc)"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
