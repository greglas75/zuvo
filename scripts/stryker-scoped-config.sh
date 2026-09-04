#!/usr/bin/env bash
#
# stryker-scoped-config.sh — emit a Stryker config scoped to an explicit file set.
#
# Why this exists: "scoped Stryker config" is the single most-requested missing template in the
# retro log, under ~30 invented names (`scoped Stryker target`, `per-target Stryker config`,
# `scoped command-runner config`, `focused Stryker config`, `scoped monorepo Stryker fallback`, …).
# Every one of them is the same five decisions, re-derived by hand, and getting any of them wrong
# produces a run that LOOKS successful:
#
#   1. `--mutate` alone does NOT scope the run. Stryker still loads the project config, which
#      routinely carries a repo-wide `mutate` array, its own reporters and its own tempDirName.
#      A CLI `--mutate` merges over it; the rest does not.
#   2. Concurrent runs collide in `.stryker-tmp`. Two scoped runs from two worktrees on one box
#      corrupt each other's sandbox and the failure surfaces as vanished dependencies mid-run
#      (`Cannot find module 'balanced-match'`) — which reads as a test failure and is not.
#   3. `coverageAnalysis: perTest` mismarks module-level ("static") mutants as SURVIVED, because
#      per-test coverage cannot attribute code that ran at import time. Those survivors are
#      artifacts of the setting, not gaps in the tests.
#   4. The report has to land somewhere the caller can actually read afterwards — especially when
#      the run is sent to the farm, where the sandbox is discarded.
#   5. next/jest and vitest need different runner wiring, and the wrong one fails at startup with
#      an error that names the test framework, not the config.
#
# This script makes those five decisions once, from the project's own manifests, and prints the
# path to a config file you pass POSITIONALLY: `npx stryker run <config>`.
#
# Usage:
#   stryker-scoped-config.sh --file <path> [--file <path> ...] [options]
#   stryker-scoped-config.sh --files-from <list-file> [options]
#
# Options:
#   --repo <dir>          project root (default: git toplevel of CWD, else CWD)
#   --out <path>          where to write the config (default: <repo>/.stryker-scoped-<tag>.conf.json)
#   --report <path>       JSON report path (default: <repo>/.stryker-scoped-<tag>.report.json)
#   --runner <name>       jest|vitest|mocha|command — default: detected
#   --concurrency <n>     default: 4 (farm-safe; a native run is the heaviest thing this repo starts)
#   --coverage <mode>     off|all|perTest — default: off  (see decision 3 above)
#   --timeout-ms <n>      default: 60000
#   --print-config        also echo the generated JSON to stdout
#
# Output — KEY=VALUE lines:
#   config_path=<abs>
#   report_path=<abs>
#   temp_dir=<name>
#   test_runner=<jest|vitest|mocha|command>
#   coverage_analysis=<off|all|perTest>
#   mutate_count=<n>
#   run_command=npx stryker run <config_path>
#
# Exit codes: 0 ok · 2 usage error · 3 no such file in the scope set
set -uo pipefail

REPO=""
OUT=""
REPORT=""
RUNNER=""
CONCURRENCY="4"
COVERAGE="off"
TIMEOUT_MS="60000"
PRINT_CONFIG=0
FILES=()

die() { echo "$1" >&2; exit "${2:-2}"; }

# Every value-taking flag proves its value exists BEFORE `shift 2`. With a trailing valueless flag,
# `shift 2` on one remaining arg fails WITHOUT consuming it, so `while [ $# -gt 0 ]` re-enters on
# the same token forever — a silent infinite loop instead of the documented exit 2. Reproduced on
# bash 3.2 in review; it spins with no output until something kills it.
need_val() { [ "$1" -ge 2 ] || die "missing value for $2"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --file)        need_val $# "$1"; FILES+=("$2"); shift 2 ;;
    --files-from)
      need_val $# "$1"
      [ -f "$2" ] || die "--files-from: no such file: $2"
      # `|| [ -n "$_l" ]` catches a final line with no trailing newline: `read` returns non-zero
      # there and the loop body would never run for it, silently scoping the run to N-1 files.
      # Stryker reports the resulting smaller mutate set as a perfectly successful run.
      while IFS= read -r _l || [ -n "$_l" ]; do
        [ -n "$_l" ] && FILES+=("$_l")
      done < "$2"
      shift 2 ;;
    --repo)        need_val $# "$1"; REPO="$2"; shift 2 ;;
    --out)         need_val $# "$1"; OUT="$2"; shift 2 ;;
    --report)      need_val $# "$1"; REPORT="$2"; shift 2 ;;
    --runner)      need_val $# "$1"; RUNNER="$2"; shift 2 ;;
    --concurrency) need_val $# "$1"; CONCURRENCY="$2"; shift 2 ;;
    --coverage)    need_val $# "$1"; COVERAGE="$2"; shift 2 ;;
    --timeout-ms)  need_val $# "$1"; TIMEOUT_MS="$2"; shift 2 ;;
    --print-config) PRINT_CONFIG=1; shift ;;
    -h|--help)     sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

[ "${#FILES[@]}" -gt 0 ] || die "no files given: pass --file <path> (repeatable) or --files-from <list>"

case "$COVERAGE" in off|all|perTest) ;; *) die "--coverage must be off|all|perTest" ;; esac
[[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || die "--concurrency must be an integer"
[[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || die "--timeout-ms must be an integer"

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
REPO="$(cd "$REPO" && pwd)" || die "--repo: no such directory"

# Normalize the scope set to repo-relative POSIX paths and verify each one exists. A typo here
# is the difference between "0 mutants, score 100%" and a real measurement, and Stryker reports
# an empty mutate set as a successful run.
# Containment is checked on the RESOLVED absolute path, for EVERY input, with no fast path.
# The first version trusted `[ -f "$REPO/$f" ]` alone for repo-relative input — but
# `$REPO/../../etc/hosts` is a file that exists, so `--file ../../../../etc/hosts` passed the
# check and landed verbatim in the generated `mutate` array. On this workstation the sibling
# directories under the parent are other production repos, so a single crafted or mistaken entry
# scoped a mutation run at code outside the repo entirely.
REL_FILES=()
for f in "${FILES[@]}"; do
  if [ -f "$REPO/$f" ]; then
    cand="$REPO/$f"
  elif [ -f "$f" ]; then
    cand="$f"
  else
    die "no such file: $f" 3
  fi
  abs="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"
  case "$abs" in
    "$REPO"/*) REL_FILES+=("${abs#"$REPO"/}") ;;
    *) die "file resolves outside --repo ($REPO): $f -> $abs" 3 ;;
  esac
done

# A tag that is unique per invocation AND per scope, so two scoped runs on one box never share a
# sandbox. Decision 2: `.stryker-tmp` is the default for every run in the repo.
TAG="$(printf '%s' "${REL_FILES[*]}" | cksum | awk '{print $1}')-$$"
[ -n "$OUT" ]    || OUT="$REPO/.stryker-scoped-$TAG.conf.json"
[ -n "$REPORT" ] || REPORT="$REPO/.stryker-scoped-$TAG.report.json"
TEMP_DIR=".stryker-tmp-$TAG"

# ── runner detection ────────────────────────────────────────────────────────
# Read the project's manifests rather than guessing from file extensions: a repo can hold jest
# and vitest at once (different packages), and the wrong choice fails at startup with an error
# that names the test framework, not this config.
detect_runner() {
  [ -n "$RUNNER" ] && { echo "$RUNNER"; return; }
  local pkg="$REPO/package.json"
  if [ -f "$pkg" ]; then
    local has
    has="$(node -e '
      const p=require(process.argv[1]);
      const d={...(p.dependencies||{}),...(p.devDependencies||{})};
      const t=JSON.stringify(p.scripts||{});
      if (d.vitest || /vitest/.test(t)) { console.log("vitest"); }
      else if (d.jest || d["next"] || /jest/.test(t)) { console.log("jest"); }
      else if (d.mocha || /mocha/.test(t)) { console.log("mocha"); }
      else { console.log(""); }
    ' "$pkg" 2>/dev/null)"
    [ -n "$has" ] && { echo "$has"; return; }
  fi
  # No signal at all: "command" runs the project's own test script and works everywhere, at the
  # cost of per-mutant suite startup. Correct-but-slow beats a runner plugin that is not installed.
  echo "command"
}
TEST_RUNNER="$(detect_runner)"

# ── config emission ─────────────────────────────────────────────────────────
# Note `mutate` here is the FULL scope, not a CLI override: decision 1. Everything the project
# config would otherwise contribute (repo-wide mutate array, its reporters, its tempDirName) is
# deliberately absent — this file is the whole configuration for this run.
node - "$REPO" "$OUT" "$REPORT" "$TEMP_DIR" "$TEST_RUNNER" "$COVERAGE" "$CONCURRENCY" "$TIMEOUT_MS" "${REL_FILES[@]}" <<'NODE'
const fs = require('fs');
const path = require('path');
const [repo, out, report, tempDir, runner, coverage, concurrency, timeoutMs, ...mutate] = process.argv.slice(2);
// Resolve runner-config candidates against the REPO, never against CWD: this script is routinely
// invoked from somewhere else, and a CWD-relative existsSync silently reports "no jest config"
// for a project that has one — which drops the transform and fails at startup.
const inRepo = (f) => fs.existsSync(path.join(repo, f));

const cfg = {
  $schema: 'https://raw.githubusercontent.com/stryker-mutator/stryker-js/master/packages/api/schema/stryker-core.json',
  _generatedBy: 'zuvo scripts/stryker-scoped-config.sh — scoped run, do not commit',
  mutate,
  testRunner: runner,
  // Decision 3. `off` runs every test for every mutant: slower, and the only setting that does
  // not mismark module-level (static) mutants as SURVIVED. A survivor list produced under
  // `perTest` needs the re-probe harness before any of it is treated as a test gap.
  coverageAnalysis: coverage,
  reporters: ['json', 'clear-text'],
  jsonReporter: { fileName: report },
  // Decision 2 + 4: a private sandbox, and a report path outside it so the farm run's discarded
  // sandbox does not take the only copy of the measurement with it.
  tempDirName: tempDir,
  cleanTempDir: true,
  concurrency: Number(concurrency),
  timeoutMS: Number(timeoutMs),
  // A scoped run measures THIS scope. A repo-wide threshold would fail the run on unrelated code.
  thresholds: { high: 100, low: 0, break: null },
  disableTypeChecks: true,
};

if (runner === 'jest') {
  // next/jest and ts-jest both build their config through a loader, so pointing Stryker at a
  // raw config object loses the transform. `projectType: custom` + configFile keeps the
  // project's own resolution intact.
  const candidates = ['jest.config.js','jest.config.ts','jest.config.mjs','jest.config.cjs','jest.config.json'];
  const found = candidates.find(inRepo);
  cfg.jest = { projectType: 'custom', enableFindRelatedTests: coverage !== 'off' };
  if (found) cfg.jest.configFile = found;
} else if (runner === 'vitest') {
  const candidates = ['vitest.config.ts','vitest.config.js','vitest.config.mts','vite.config.ts','vite.config.js'];
  const found = candidates.find(inRepo);
  if (found) cfg.vitest = { configFile: found };
} else if (runner === 'command') {
  // `npm test` with no file filter: correct everywhere, slowest. Override with --runner once the
  // project's real runner plugin is installed.
  cfg.commandRunner = { command: 'npm test' };
}

fs.writeFileSync(out, JSON.stringify(cfg, null, 2) + '\n');
NODE
rc=$?
[ "$rc" -eq 0 ] || die "failed to write config (node exited $rc)" 2

printf 'config_path=%s\n' "$OUT"
printf 'report_path=%s\n' "$REPORT"
printf 'temp_dir=%s\n' "$TEMP_DIR"
printf 'test_runner=%s\n' "$TEST_RUNNER"
printf 'coverage_analysis=%s\n' "$COVERAGE"
printf 'mutate_count=%s\n' "${#REL_FILES[@]}"
# The CWD is pinned on purpose: `mutate` entries are repo-relative and Stryker resolves them
# against the RUN's working directory. This script is routinely invoked from elsewhere, and a
# command run from the wrong directory matches zero files — which Stryker reports as a successful
# 100% run, the exact silent failure the scope validation above exists to prevent.
printf 'run_command=(cd %s && npx stryker run %s)\n' "$REPO" "$OUT"

if [ "$PRINT_CONFIG" = "1" ]; then
  echo "--- config ---"
  cat "$OUT"
fi
