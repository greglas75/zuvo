#!/usr/bin/env bash
# scripts/zuvo-home/verify-tests — the single-verdict verification helper.
#
# The helper exists to collapse four separate fix-and-rerun loops into one command, so the
# properties worth testing are the ones an agent would otherwise have to judge: does it stop
# (budget), does it refuse to measure a red suite, does it report a hash drift, does it read
# a runner's real numbers rather than the first number that looks like one.
#
# Every scenario runs against STUB `npx` / `npm` on PATH. A real vitest or stryker invocation
# here would be both slow and a lie: what is under test is the helper's parsing and control
# flow, not StrykerJS.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/zuvo-home/verify-tests"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$HELPER" ] || { bad "helper missing or not executable: $HELPER"; exit 1; }

# ── fake zuvo install: the helper locates test-coverage-gate.py through ZUVO_BASE ─────────
FAKE_BASE="$TMP/zuvo-base"; mkdir -p "$FAKE_BASE/scripts"
cat > "$FAKE_BASE/scripts/test-coverage-gate.py" <<'PY'
import json, os, sys
if "boundaries" in sys.argv:
    # verify-tests asks for this to name the obligation a surviving mutant failed.
    print(json.dumps({"schema": "zuvo-boundaries/v1", "available": True,
                      "obligations": [{"kind": "comparison", "op": "<", "line": 70,
                                       "expr": "n < 0", "left": "n", "right": "0"}]}))
    sys.exit(0)
mode = os.environ.get("STUB_GATE", "pass")
print("COVERAGE GATE (executable) - phase: final")
if mode == "pass":
    print("Public entry points: 4/4 FULL")
    print("Uncovered owned rows: 0")
    sys.exit(0)
if mode == "degraded":
    print("extraction: textual")
    sys.exit(3)
print("Uncovered owned rows: 0")
print("missing symbols: alpha, beta")
print("FAIL: MISSING SYMBOL: alpha is a public entry point in production but has no manifest row")
print("FAIL: MISSING SYMBOL: beta is a public entry point in production but has no manifest row")
print("RESULT: FAIL (2 violations)")
sys.exit(1)
PY

# ── stub runners ─────────────────────────────────────────────────────────────────────────
STUB="$TMP/stubbin"; mkdir -p "$STUB"
NPM_CANARY="$TMP/npm-canary"
export JEST_ARGS_CANARY="$TMP/jest-args"
export JEST_CFG_CANARY="$TMP/jest-cfg"
export TSC_ARGS_CANARY="$TMP/tsc-args"

cat > "$STUB/npx" <<PYEOF
#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
tool = argv[0] if argv else ""

if tool == "vitest":
    covdir = None
    for a in argv:
        if a.startswith("--coverage.reportsDirectory="):
            covdir = a.split("=", 1)[1]
    if covdir:
        os.makedirs(covdir, exist_ok=True)
        pct = float(os.environ.get("STUB_COV_PCT", "95"))
        entry = {k: {"pct": pct} for k in ("statements", "branches", "functions", "lines")}
        entry["lines"]["uncoveredLines"] = [41, 42]
        json.dump({"total": entry}, open(os.path.join(covdir, "coverage-summary.json"), "w"))
        print("coverage run")
        sys.exit(0)
    # ANSI on purpose: real vitest colours this even when stdout is not a TTY, and the
    # helper must strip it before anchoring on the Tests line.
    if os.environ.get("STUB_SUITE", "green") == "red":
        print("\x1b[31m FAIL \x1b[39m src/thing.spec.ts > rejects empty input")
        print("\x1b[2m Test Files \x1b[22m \x1b[31m1 failed\x1b[39m (1)")
        print("\x1b[2m      Tests \x1b[22m \x1b[31m2 failed\x1b[39m | \x1b[32m33 passed\x1b[39m (35)")
        sys.exit(1)
    print("\x1b[2m Test Files \x1b[22m \x1b[32m1 passed\x1b[39m\x1b[90m (1)\x1b[39m")
    print("\x1b[2m      Tests \x1b[22m \x1b[32m35 passed\x1b[39m\x1b[90m (35)\x1b[39m")
    sys.exit(0)

if tool == "jest":
    open(os.environ["JEST_ARGS_CANARY"], "a").write(" ".join(argv) + "\n")
    covdir = None
    for i, a in enumerate(argv):
        if a.startswith("--coverageDirectory="):
            covdir = a.split("=", 1)[1]
    if covdir:
        os.makedirs(covdir, exist_ok=True)
        mode = os.environ.get("STUB_JEST_COV", "ok")
        if mode == "unknown":
            entry = {k: {"pct": "Unknown"} for k in ("statements", "branches", "functions", "lines")}
            json.dump({"total": entry}, open(os.path.join(covdir, "coverage-summary.json"), "w"))
        elif mode == "multifile":
            e = {k: {"pct": 91.0} for k in ("statements", "branches", "functions", "lines")}
            json.dump({"total": e, "/elsewhere/a.ts": e, "/elsewhere/b.ts": e},
                      open(os.path.join(covdir, "coverage-summary.json"), "w"))
        else:
            pct = float(os.environ.get("STUB_COV_PCT", "95"))
            e = {k: {"pct": pct} for k in ("statements", "branches", "functions", "lines")}
            json.dump({"total": e, os.path.abspath(os.environ["FX_PROD"]): e},
                      open(os.path.join(covdir, "coverage-summary.json"), "w"))
        print("coverage run")
        sys.exit(0)
    if os.environ.get("STUB_JEST_SKIP") == "1":
        print("Test Suites: 1 passed, 1 total")
        print("Tests:       35 skipped, 15 passed, 50 total")
    else:
        print("Test Suites: 1 passed, 1 total")
        print("Tests:       7 passed, 7 total")
    sys.exit(0)

if tool == "tsc":
    open(os.environ["TSC_ARGS_CANARY"], "a").write(" ".join(argv) + "\n")
    mode = os.environ.get("STUB_TSC", "clean")
    # A monorepo with pre-existing debt: errors in OTHER files must not become this run's gaps.
    print("src/other/legacy.ts(11,3): error TS2322: Type 'string' is not assignable to 'number'.")
    print("src/other/legacy.ts(19,7): error TS7006: Parameter 'x' implicitly has an 'any' type.")
    if mode == "own":
        print("src/thing.spec.ts(42,9): error TS2554: Expected 1 arguments, but got 2.")
    sys.exit(1 if mode in ("own", "clean") else 0)

if tool == "stryker":
    cfg = json.load(open(argv[2]))
    # Record what the generated runner config actually asked for: the sandbox bug this
    # helper hit is invisible unless the testMatch entries are inspected.
    jr = cfg.get("jest") or {}
    if jr.get("configFile"):
        open(os.environ["JEST_CFG_CANARY"], "w").write(open(jr["configFile"]).read())
    if os.environ.get("STUB_STRYKER", "ok") == "crash":
        print("TypeError: ts.parseConfigFileTextToJson is not a function")
        sys.exit(1)
    n_surv = int(os.environ.get("STUB_SURVIVORS", "0"))
    mutants = [{"status": "Killed", "mutatorName": "Arithmetic",
                "location": {"start": {"line": 10}}} for _ in range(9)]
    for i in range(n_surv):
        mutants.append({
            "status": "NoCoverage" if i == 0 else "Survived",
            "mutatorName": "ConditionalExpression",
            "replacement": "true",
            "location": {"start": {"line": 70 + i}},
        })
    out = cfg["jsonReporter"]["fileName"]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({"files": {"src/thing.ts": {"mutants": mutants}}}, open(out, "w"))
    # A real run leaves this behind; the helper must clear it.
    os.makedirs(os.path.join(os.getcwd(), ".stryker-tmp"), exist_ok=True)
    print("stryker done")
    sys.exit(0)

sys.exit(0)
PYEOF
chmod +x "$STUB/npx"

cat > "$STUB/npm" <<EOF
#!/bin/sh
echo "npm invoked: \$*" >> "$NPM_CANARY"
exit 1
EOF
chmod +x "$STUB/npm"

# ── fixture repo ─────────────────────────────────────────────────────────────────────────
mkrepo() { # mkrepo <dir> [with-stryker]
  local d="$1"
  mkdir -p "$d/src" "$d/zuvo/contracts" "$d/node_modules/.bin"
  printf '{"name":"fx","devDependencies":{"vitest":"^3.0.0"}}\n' > "$d/package.json"
  printf '{"compilerOptions":{"strict":true}}\n' > "$d/tsconfig.json"
  mkdir -p "$d/node_modules/.bin"; : > "$d/node_modules/.bin/tsc"; chmod +x "$d/node_modules/.bin/tsc"
  printf 'export const alpha = (n) => n + 1;\n' > "$d/src/thing.ts"
  printf 'it("works", () => {});\n' > "$d/src/thing.spec.ts"
  if [ "${2:-}" = with-stryker ]; then
    mkdir -p "$d/node_modules/@stryker-mutator/core" "$d/node_modules/@stryker-mutator/vitest-runner"
  fi
  python3 - "$d" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
h = hashlib.sha256(open(os.path.join(d, "src/thing.ts"), "rb").read()).hexdigest()
json.dump({"schema": "zuvo-coverage-manifest/v1",
           "production_file": "src/thing.ts",
           "production_sha256": h,
           "stack": "ts",
           "test_files": ["src/thing.spec.ts"],
           "quality_gates": {"Q7": 1, "Q11": 1},
           "status": "final", "symbols": []},
          open(os.path.join(d, "zuvo/contracts/thing.coverage.json"), "w"), indent=1)
PY
}

vt() { # vt <repo> [extra args...] ; stdout+stderr captured to $TMP/out
  local d="$1"; shift
  PATH="$STUB:$PATH" ZUVO_BASE="$FAKE_BASE" \
    "$HELPER" --manifest "$d/zuvo/contracts/thing.coverage.json" --repo-root "$d" "$@" \
    > "$TMP/out" 2>&1
  return $?
}

# ── (1) unreadable manifest → exit 2, and nothing is claimed ─────────────────────────────
R="$TMP/r1"; mkrepo "$R"
PATH="$STUB:$PATH" ZUVO_BASE="$FAKE_BASE" "$HELPER" --manifest "$R/nope.json" --repo-root "$R" \
  > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "missing manifest exits 2" || bad "missing manifest exit $rc (want 2)"
grep -q "cannot read manifest" "$TMP/out" \
  && pass "missing manifest names the file" || bad "missing manifest message: $(cat "$TMP/out")"

# ── (2) manifest points at a production file that is not there → exit 2 ──────────────────
R="$TMP/r2"; mkrepo "$R"; rm "$R/src/thing.ts"
vt "$R"; rc=$?
[ "$rc" -eq 2 ] && pass "absent production file exits 2" || bad "absent production exit $rc (want 2)"
grep -q "missing file" "$TMP/out" || bad "absent production file not reported: $(cat "$TMP/out")"

# ── (3) green suite, everything passes, no stryker installed → exit 0 ────────────────────
R="$TMP/r3"; mkrepo "$R"
STUB_GATE=pass STUB_COV_PCT=95 vt "$R" --no-install; rc=$?
[ "$rc" -eq 0 ] && pass "all-green exits 0" || bad "all-green exit $rc (want 0); $(cat "$TMP/out")"
grep -q "Do NOT re-run this command" "$TMP/out" \
  && pass "green verdict says not to re-run" || bad "green verdict lacks the stop instruction"
grep -qE "suite +PASS +35 tests passed" "$TMP/out" \
  && pass "ANSI-coloured 'Tests 35 passed' is read as 35, not as Test Files' 1" \
  || bad "test count misparsed: $(grep -E '^  suite' "$TMP/out")"
grep -qE "mutation +SKIP" "$TMP/out" \
  && pass "no stryker → mutation SKIP (not silently green)" || bad "mutation state wrong"

# ── (4) --no-install really suppresses the npm install ───────────────────────────────────
[ ! -f "$NPM_CANARY" ] && pass "--no-install never shells out to npm" \
  || bad "npm was invoked despite --no-install: $(cat "$NPM_CANARY")"

# ── (5) without --no-install, a missing runner triggers ONE --no-save install ────────────
R="$TMP/r5"; mkrepo "$R"
rm -f "$NPM_CANARY"
STUB_GATE=pass vt "$R"; rc=$?
grep -q -- "--no-save" "$NPM_CANARY" 2>/dev/null \
  && pass "absent runner is installed with --no-save (no lockfile write)" \
  || bad "install not attempted or not --no-save: $(cat "$NPM_CANARY" 2>/dev/null)"
grep -qE "mutation +ERROR .*install failed" "$TMP/out" \
  && pass "failed install is reported as an error, not skipped silently" \
  || bad "failed install misreported: $(grep -E '^  mutation' "$TMP/out")"

# ── (6) red suite: downstream checks do NOT run ──────────────────────────────────────────
R="$TMP/r6"; mkrepo "$R" with-stryker
STUB_SUITE=red STUB_GATE=pass vt "$R"; rc=$?
[ "$rc" -eq 1 ] && pass "red suite exits 1" || bad "red suite exit $rc (want 1)"
grep -qE "coverage-gate .*not run — suite is red" "$TMP/out" \
  && pass "gate is not run against a red suite" \
  || bad "gate ran on a red suite: $(grep -E 'coverage-gate' "$TMP/out")"
grep -qE "mutation .*not run — suite is red" "$TMP/out" \
  && pass "mutation is not run against a red suite" || bad "mutation ran on a red suite"
grep -q "rejects empty input" "$TMP/out" \
  && pass "failing test names surface as gaps" || bad "no failing test named in the gap list"
grep -q "a red suite scores 0 and is a terminal state" "$TMP/out" \
  && pass "a red suite names its two legal exits, at the point a run is most likely to stop" \
  || bad "red suite does not say how to resolve"

# ── (7) gate failure: only the validator's own FAIL lines become gaps ────────────────────
R="$TMP/r7"; mkrepo "$R"
STUB_GATE=fail vt "$R" --no-install; rc=$?
[ "$rc" -eq 1 ] && pass "gate failure exits 1" || bad "gate failure exit $rc (want 1)"
grep -q "MISSING SYMBOL: alpha" "$TMP/out" \
  && pass "validator violations are listed individually" || bad "validator violations not listed"
grep -qE '^  - Uncovered owned rows: 0' "$TMP/out" \
  && bad "summary counter leaked into the gap list (reads as a contradiction)" \
  || pass "summary counters stay out of the gap list"

# ── (8) coverage below threshold → the shortfall is named with its number ────────────────
R="$TMP/r8"; mkrepo "$R"
STUB_GATE=pass STUB_COV_PCT=60 vt "$R" --no-install; rc=$?
[ "$rc" -eq 1 ] && pass "low coverage exits 1" || bad "low coverage exit $rc (want 1)"
grep -q "statements 60.0% < 85%" "$TMP/out" \
  && pass "coverage shortfall names measured vs required" || bad "coverage shortfall not itemised"
grep -q "uncovered lines: \[41, 42\]" "$TMP/out" \
  && pass "uncovered lines are handed over, not just the percentage" || bad "uncovered lines missing"

# ── (9) mutation survivors: capped, NoCoverage first, remainder counted ──────────────────
R="$TMP/r9"; mkrepo "$R" with-stryker
STUB_GATE=pass STUB_SURVIVORS=8 vt "$R" --survivor-cap 3; rc=$?
grep -qE "mutation +FAIL +52\.9%" "$TMP/out" \
  && pass "mutation score computed from the report (9 killed / 17 tested)" \
  || bad "mutation score wrong: $(grep -E '^  mutation' "$TMP/out")"
[ "$(grep -c '^  - NoCoverage\|^  - Survived' "$TMP/out")" -eq 3 ] \
  && pass "survivor list respects --survivor-cap" \
  || bad "survivor cap ignored ($(grep -c '^  - NoCoverage\|^  - Survived' "$TMP/out") listed)"
grep -q "^  - NoCoverage" "$TMP/out" && [ "$(grep -n 'NoCoverage\|Survived' "$TMP/out" | head -1 | grep -c NoCoverage)" -eq 1 ] \
  && pass "no-coverage mutants lead the fix list" || bad "survivor ordering does not prioritise NoCoverage"
grep -q "comparison obligation on this line: n < 0" "$TMP/out" \
  && pass "a survivor names the boundary obligation it failed, not just a mutant id" \
  || bad "survivor not annotated with its obligation: $(grep -m1 'NoCoverage\|Survived' "$TMP/out")"
grep -q "5 more survivors" "$TMP/out" \
  && pass "survivors past the cap are counted, not dropped" || bad "remaining survivors not reported"
[ ! -d "$R/.stryker-tmp" ] && pass "runner debris is cleared" || bad ".stryker-tmp left behind"

# ── (10) budget: the helper stops on its own ─────────────────────────────────────────────
R="$TMP/r10"; mkrepo "$R"
for _ in 1 2; do STUB_GATE=fail vt "$R" --no-install --budget 3 >/dev/null 2>&1; done
STUB_GATE=fail vt "$R" --no-install --budget 3; rc=$?
[ "$rc" -eq 4 ] && pass "third pass with gaps exits 4" || bad "budget exhaustion exit $rc (want 4)"
grep -q "BUDGET EXHAUSTED" "$TMP/out" \
  && pass "budget exhaustion is stated, not implied" || bad "no BUDGET EXHAUSTED line"
grep -q "BLOCKED_INCOMPLETE" "$TMP/out" \
  && pass "exhaustion routes to BLOCKED_INCOMPLETE, not to another pass" \
  || bad "exhaustion does not name the terminal state"
grep -q "pass 3 of 3" "$TMP/out" \
  && pass "pass counter is visible on every run" || bad "pass counter missing"

# ── (10b) the clock is a SECOND stop condition, independent of the pass count ────────────
R="$TMP/r10b"; mkrepo "$R"
STUB_GATE=fail vt "$R" --no-install --budget 99 --time-budget 0 >/dev/null 2>&1
# Backdate the recorded start so the clock reads as expired without sleeping in a test.
python3 - "$R/zuvo/contracts/thing.coverage.json.verify-state.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["started_epoch"] = int(time.time()) - 20 * 60
json.dump(d, open(p, "w"))
PY
STUB_GATE=fail vt "$R" --no-install --budget 99 --time-budget 15; rc=$?
[ "$rc" -eq 4 ]   && pass "the clock stops the loop even with 97 passes of budget left"   || bad "time budget ignored (rc=$rc)"
grep -q "minutes elapsed of a 15-minute budget" "$TMP/out"   && pass "exhaustion says it was the clock, not the pass count"   || bad "time exhaustion not attributed: $(grep VERDICT "$TMP/out")"
grep -qE "of 15 min" "$TMP/out"   && pass "every pass prints the clock, so the budget is visible before it runs out"   || bad "elapsed not shown in the header"

R="$TMP/r10c"; mkrepo "$R"
STUB_GATE=fail vt "$R" --no-install --budget 99 --time-budget 0; rc=$?
[ "$rc" -eq 1 ] && pass "--time-budget 0 disables the clock" || bad "time-budget 0 exit $rc (want 1)"

# ── (11) --reset-budget clears the counter ───────────────────────────────────────────────
STUB_GATE=fail vt "$R" --no-install --budget 3 --reset-budget; rc=$?
[ "$rc" -eq 1 ] && pass "--reset-budget restarts the count" || bad "--reset-budget exit $rc (want 1)"

# ── (12) production hash drift is caught ─────────────────────────────────────────────────
R="$TMP/r12"; mkrepo "$R"
python3 - "$R" <<'PY'
import json, sys, os
p = os.path.join(sys.argv[1], "zuvo/contracts/thing.coverage.json")
m = json.load(open(p)); m["production_sha256"] = "0" * 64
json.dump(m, open(p, "w"))
PY
STUB_GATE=pass vt "$R" --no-install; rc=$?
grep -qE "production-hash +FAIL" "$TMP/out" \
  && pass "hash drift against the frozen manifest is a FAIL" || bad "hash drift not detected"
[ "$rc" -ne 0 ] && pass "hash drift cannot exit 0" || bad "hash drift exited 0"

# ── (13) --json is machine-readable and carries the same exit ────────────────────────────
R="$TMP/r13"; mkrepo "$R"
STUB_GATE=pass STUB_COV_PCT=95 vt "$R" --no-install --json; rc=$?
python3 - "$TMP/out" "$rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schema"] == "zuvo-verify/v1", d.get("schema")
assert d["exit"] == int(sys.argv[2]), (d["exit"], sys.argv[2])
assert d["runner"] == "vitest"
assert {r["check"] for r in d["results"]} >= {"suite", "coverage-gate", "coverage", "production-hash"}
PY
[ $? -eq 0 ] && pass "--json parses and its exit field matches the process exit" \
  || bad "--json output malformed: $(head -3 "$TMP/out")"

# ── (14) monorepo: the runner is found in the workspace package, not the root ────────────
R="$TMP/r14"; mkdir -p "$R/apps/api"
printf '{"name":"root","private":true}\n' > "$R/package.json"
mkrepo "$R/apps/api"
python3 - "$R" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "apps/api/zuvo/contracts/thing.coverage.json")
m = json.load(open(p))
m["production_file"] = "apps/api/src/thing.ts"
m["test_files"] = ["apps/api/src/thing.spec.ts"]
json.dump(m, open(p, "w"))
PY
PATH="$STUB:$PATH" ZUVO_BASE="$FAKE_BASE" STUB_GATE=pass \
  "$HELPER" --manifest "$R/apps/api/zuvo/contracts/thing.coverage.json" --repo-root "$R" \
  --no-install > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "monorepo spec resolves against the workspace package" \
  || bad "monorepo run exit $rc: $(cat "$TMP/out")"

# ── (15) degraded gate (exit 3) is neither a pass nor a hard fail ────────────────────────
R="$TMP/r15"; mkrepo "$R"
STUB_GATE=degraded vt "$R" --no-install; rc=$?
grep -qE "coverage-gate +DEGRADED" "$TMP/out" \
  && pass "textual extraction is reported DEGRADED" || bad "exit-3 gate not surfaced as DEGRADED"
grep -q "BLOCKED_DEGRADED" "$TMP/out" \
  && pass "DEGRADED names the evidence-quality state" || bad "DEGRADED lacks the state name"

# ── jest projects (rs_be / NestJS shape: config under package.json#jest, rootDir "src") ──
mkjest() { # mkjest <dir> [with-stryker]
  local d="$1"
  mkdir -p "$d/src" "$d/zuvo/contracts"
  cat > "$d/package.json" <<'JSON'
{"name":"jx","devDependencies":{"jest":"^29.7.0"},
 "jest":{"rootDir":"src","testRegex":".*\\.spec\\.ts$","transform":{"^.+\\.ts$":"ts-jest"}}}
JSON
  printf 'export const band = (n) => n > 0 ? "hi" : "lo";
' > "$d/src/scoring.ts"
  printf 'it("works", () => {});
' > "$d/src/scoring.spec.ts"
  if [ "${2:-}" = with-stryker ]; then
    mkdir -p "$d/node_modules/@stryker-mutator/core" "$d/node_modules/@stryker-mutator/jest-runner"
  fi
  python3 - "$d" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
h = hashlib.sha256(open(os.path.join(d, "src/scoring.ts"), "rb").read()).hexdigest()
json.dump({"schema": "zuvo-coverage-manifest/v1", "production_file": "src/scoring.ts",
           "production_sha256": h, "stack": "ts",
           "test_files": ["src/scoring.spec.ts"], "quality_gates": {"Q7": 1, "Q11": 1},
           "status": "final", "symbols": []},
          open(os.path.join(d, "zuvo/contracts/scoring.coverage.json"), "w"), indent=1)
PY
}

jt() { # jt <repo> [extra args...]
  local d="$1"; shift
  PATH="$STUB:$PATH" ZUVO_BASE="$FAKE_BASE" FX_PROD="$d/src/scoring.ts" \
    "$HELPER" --manifest "$d/zuvo/contracts/scoring.coverage.json" --repo-root "$d" "$@" \
    > "$TMP/out" 2>&1
  return $?
}

# ── (16) jest is detected and its mutation plugin is the one required ────────────────────
R="$TMP/j16"; mkjest "$R"
rm -f "$NPM_CANARY"
STUB_GATE=pass jt "$R"
grep -q "jest-runner" "$NPM_CANARY" 2>/dev/null \
  && pass "jest project installs @stryker-mutator/jest-runner, not the vitest one" \
  || bad "wrong stryker plugin for jest: $(cat "$NPM_CANARY" 2>/dev/null)"

# ── (17) generated jest config anchors testMatch on <rootDir>, never an absolute path ────
R="$TMP/j17"; mkjest "$R" with-stryker
rm -f "$JEST_CFG_CANARY"
STUB_GATE=pass jt "$R"
if [ -f "$JEST_CFG_CANARY" ]; then
  grep -q "<rootDir>" "$JEST_CFG_CANARY" \
    && pass "generated jest config anchors testMatch on <rootDir> (survives Stryker's sandbox)" \
    || bad "testMatch not <rootDir>-anchored: $(grep -i testmatch "$JEST_CFG_CANARY")"
  grep -q "testRegex, testMatch, ...rest" "$JEST_CFG_CANARY" \
    && pass "inherited testRegex is dropped (jest rejects both at once)" \
    || bad "testRegex not stripped from the generated config"
  grep -q "$TMP" "$JEST_CFG_CANARY" \
    && bad "generated jest config embeds an absolute host path" \
    || pass "generated jest config embeds no absolute host path"
else
  bad "stryker was never invoked for the jest project"
fi

# ── (18) jest coverage glob is rootDir-independent ───────────────────────────────────────
R="$TMP/j18"; mkjest "$R"
rm -f "$JEST_ARGS_CANARY"
STUB_GATE=pass STUB_COV_PCT=95 jt "$R" --no-install
grep -q -- "--collectCoverageFrom=\*\*/scoring.ts" "$JEST_ARGS_CANARY" 2>/dev/null \
  && pass "collectCoverageFrom uses a rootDir-independent glob" \
  || bad "collectCoverageFrom would miss under rootDir=src: $(grep -o -- '--collectCoverageFrom=[^ ]*' "$JEST_ARGS_CANARY" 2>/dev/null)"
grep -qE "coverage +PASS +statements 95" "$TMP/out" \
  && pass "jest coverage numbers are read for the file under test" \
  || bad "jest coverage not attributed: $(grep -E '^  coverage' "$TMP/out")"

# ── (19) jest "Unknown" pct is not scored as 0% ──────────────────────────────────────────
R="$TMP/j19"; mkjest "$R"
STUB_GATE=pass STUB_JEST_COV=unknown jt "$R" --no-install; rc=$?
grep -qE "coverage +SKIP +not measured" "$TMP/out" \
  && pass "'Unknown' coverage is reported unmeasured, not as a 0% shortfall" \
  || bad "Unknown pct mishandled: $(grep -E '^  coverage' "$TMP/out")"
grep -q "statements 0.0% < 85%" "$TMP/out" \
  && bad "Unknown pct produced a fabricated 0% failure" \
  || pass "no fabricated shortfall from unmeasured coverage"

# ── (20) a summary covering other files is not reported as this file's coverage ──────────
R="$TMP/j20"; mkjest "$R"
STUB_GATE=pass STUB_JEST_COV=multifile jt "$R" --no-install
grep -q "coverage not attributable" "$TMP/out" \
  && pass "multi-file summary without this file is SKIP, not 'total' passed off as the file" \
  || bad "total was reported as the file's coverage: $(grep -E '^  coverage' "$TMP/out")"

# ── (21) jest's "N skipped, M passed" is read correctly and the skips are surfaced ───────
R="$TMP/j21"; mkjest "$R"
STUB_GATE=pass STUB_JEST_SKIP=1 jt "$R" --no-install; rc=$?
grep -qE "suite +PASS +15 tests passed" "$TMP/out" \
  && pass "jest 'Tests: 35 skipped, 15 passed' reads as 15, not as Test Suites' 1" \
  || bad "jest test count misparsed: $(grep -E '^  suite' "$TMP/out")"
grep -q "35 SKIPPED" "$TMP/out" \
  && pass "skipped tests are surfaced, not silently counted as a green suite" \
  || bad "35 skipped tests were not reported"
[ "$rc" -ne 0 ] && pass "a heavily-skipped suite cannot exit 0" || bad "skipped suite exited 0"

# ── (22) typecheck: only errors in the files under test become gaps ──────────────────────
R="$TMP/t22"; mkrepo "$R"
rm -f "$TSC_ARGS_CANARY"
STUB_GATE=pass STUB_TSC=clean vt "$R" --no-install; rc=$?
grep -qE "typecheck +PASS +0 errors in the written spec" "$TMP/out" \
  && pass "pre-existing errors in other files do not fail this run" \
  || bad "typecheck attribution wrong: $(grep -E '^  typecheck' "$TMP/out")"
grep -q "2 elsewhere" "$TMP/out" \
  && pass "pre-existing count is reported, so silence is not read as a clean project" \
  || bad "pre-existing errors not surfaced"
grep -q -- "--incremental" "$TSC_ARGS_CANARY" 2>/dev/null \
  && pass "typecheck runs incrementally (57s cold vs 16s warm on the rig)" \
  || bad "typecheck not incremental: $(cat "$TSC_ARGS_CANARY" 2>/dev/null)"
grep -q -- "-p tsconfig.json" "$TSC_ARGS_CANARY" 2>/dev/null \
  && pass "typecheck targets the OWNING project, not the monorepo root" \
  || bad "typecheck project scope wrong"

# ── (23) a type error in the spec IS this run's problem ──────────────────────────────────
R="$TMP/t23"; mkrepo "$R"
STUB_GATE=pass STUB_TSC=own vt "$R" --no-install; rc=$?
grep -q "thing.spec.ts:42 TS2554" "$TMP/out" \
  && pass "a type error in the written spec becomes a gap" || bad "own-file type error not raised"
grep -q "legacy.ts" "$TMP/out" \
  && bad "another file's type error leaked into the gap list" \
  || pass "other files' type errors stay out of the gap list"
[ "$rc" -eq 1 ] && pass "own type error exits 1" || bad "own type error exit $rc (want 1)"

# ── (24) the expensive checks wait on COVERAGE, not on the manifest gate ─────────────────
# Gating them on the gate starved a whole benchmark case: the gate never went green, mutation
# never ran, and the suite finished unmeasured at exactly the no-skill control's score. The
# gate is bookkeeping; coverage and the suite are what make a mutation number mean anything.
R="$TMP/m24"; mkrepo "$R" with-stryker
rm -f "$TSC_ARGS_CANARY"
STUB_GATE=pass STUB_COV_PCT=60 STUB_TSC=clean vt "$R"; rc=$?
grep -qE "mutation +DEFER" "$TMP/out" \
  && pass "mutation is DEFERred while coverage is below threshold" \
  || bad "mutation ran under inadequate coverage: $(grep -E '^  mutation' "$TMP/out")"

grep -qE "typecheck +DEFER" "$TMP/out" \
  && pass "typecheck is DEFERred too (57s cold — the block that crosses the 120s Bash window)" \
  || bad "typecheck ran under inadequate coverage: $(grep -E '^  typecheck' "$TMP/out")"
grep -q -- "-p tsconfig.json" "$TMP/tsc-args" 2>/dev/null && [ -s "$TMP/tsc-args" ] \
  && bad "tsc was invoked despite the deferral" || pass "no tsc process is started on a deferred pass"
grep -qE "(mutation|typecheck) +SKIP" "$TMP/out" \
  && bad "a deferral reported SKIP — Step 3.3 keys on SKIP to run hand probes, so this sends the agent to do the expensive thing manually" \
  || pass "deferral never reports SKIP, which means 'cannot run here' and triggers hand probes"

R="$TMP/m24c"; mkrepo "$R" with-stryker
STUB_GATE=fail STUB_COV_PCT=95 STUB_SURVIVORS=2 vt "$R"
grep -qE "mutation +(FAIL|PASS)" "$TMP/out" \
  && pass "a FAILING manifest gate no longer blocks mutation — bookkeeping is not test quality" \
  || bad "gate failure still starves the run of its mutation signal"

R="$TMP/m24b"; mkrepo "$R" with-stryker
STUB_GATE=pass STUB_COV_PCT=60 STUB_SURVIVORS=2 vt "$R" --force-mutation
grep -qE "mutation +(FAIL|PASS)" "$TMP/out" \
  && pass "--force-mutation overrides the deferral" \
  || bad "--force-mutation did not run mutation: $(grep -E '^  mutation' "$TMP/out")"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
