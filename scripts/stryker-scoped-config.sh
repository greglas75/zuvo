#!/usr/bin/env bash
#
# stryker-scoped-config.sh — emit a Stryker config scoped to the LINES a branch changed or added.
#
# Why this exists: "scoped Stryker config" is the single most-requested missing template in the
# retro log, under ~30 invented names (`scoped Stryker target`, `per-target Stryker config`,
# `scoped command-runner config`, `focused Stryker config`, `scoped monorepo Stryker fallback`, …).
# Every one of them is the same six decisions, re-derived by hand, and getting any of them wrong
# produces a run that LOOKS successful:
#
#   1. `--mutate` alone does NOT scope the run. Stryker still loads the project config, which
#      routinely carries a repo-wide `mutate` array, its own reporters and its own tempDirName.
#      A CLI `--mutate` merges over it; the rest does not.
#   2. Concurrent runs collide in `.stryker-tmp`. Two scoped runs from two worktrees on one box
#      corrupt each other's sandbox and the failure surfaces as vanished dependencies mid-run
#      (`Cannot find module 'balanced-match'`) — which reads as a test failure and is not.
#   3. Static (module-level) mutants are IGNORED (`ignoreStatic: true`). Per-test coverage cannot
#      attribute code that runs at import time, so under `perTest` they are mismarked SURVIVED, and
#      running them honestly costs the whole suite per mutant (71–83% of a 2026-10-02 farm
#      campaign's time, by Stryker's own warning). Stryker accepts ignoreStatic ONLY with
#      `coverageAnalysis: perTest`, so that pair is the default; `--include-static` restores `off`.
#   4. The report has to land somewhere the caller can actually read afterwards — especially when
#      the run is sent to the farm, where the sandbox is discarded.
#   5. next/jest and vitest need different runner wiring, and the wrong one fails at startup with
#      an error that names the test framework, not the config.
#   6. The scope is the CHANGED LINES — never unchanged files. 2026-10-02: a `--files-from` campaign
#      mutated 204 whole files = 33,367 lines for a branch that changed 2,880 (8%); 97 of the files
#      were untouched by the branch; 15+ hours on the farm. So: one Stryker range (`file:start-end`)
#      per diff hunk, an added file whole, and a `--file`/`--files-from` list INTERSECTED with the
#      diff (unchanged files dropped, changed ones narrowed). `--whole-files` is the explicit opt-out.
#
# Usage: stryker-scoped-config.sh [--diff <base>] [--file <p> ... | --files-from <list>] [options]
#   no --file          the lines this branch changed (committed + uncommitted + untracked files)
#   --file/--files-from  those files ∩ the diff
#
# Base: merge-base(HEAD, <base>) — with no --diff, the NEAREST of <remote>/HEAD and
# <remote>/{develop,main,master} (fewest commits merge-base..HEAD; local branches only when no remote
# ref exists), so a branch cut from develop is not diffed against an origin/HEAD of main. The diff is
# taken against the WORKING TREE; untracked, non-ignored files count as added.
#
# Options:
#   --diff <base>         diff against merge-base(HEAD, <base>)
#   --whole-files         mutate whole files (the listed ones, else every changed one) — NOT the default
#   --include-static      do not ignore static mutants; implies --coverage off unless given
#   --repo <dir>          project root (default: git toplevel of CWD, else CWD); a monorepo package
#                         dir scopes the diff to it, paths relative to it
#   --out <path>          config path (default: <repo>/.stryker-scoped-<tag>.conf.json)
#   --report <path>       JSON report path (default: <repo>/.stryker-scoped-<tag>.report.json)
#   --runner <name>       jest|vitest|mocha|command — default: detected
#   --concurrency <n>     default: 4 (farm-safe; a native run is the heaviest thing this repo starts)
#   --coverage <mode>     off|all|perTest — default: perTest (off with --include-static)
#   --timeout-ms <n>      default: 60000
#   --no-progress-timeout <s>  abort the run after <s> s without progress (stryker-run-watchdog.sh,
#                         exit 124) — default: 600
#   --dry-run-timeout-min <n>  Stryker's initial-test-run limit (dryRunTimeoutMinutes) — default: 5
#   --print-config        also echo the generated JSON to stdout
#   --vitest-config <p>   (vitest) the Vitest config to run under, instead of the one nearest the files;
#                         a multi-project one (test.projects/test.workspace) is refused (exit 2)
#   --test-file <p> ... | --tests-from <list>
#                         (vitest) the tests that cover the scope, instead of the co-located ones
#
# Mutable: .js .jsx .ts .tsx .mjs .cjs .mts .cts .vue .svelte, minus *.d.ts, *.test|spec|stories|
# config.*, and anything under __tests__ __mocks__ __fixtures__ test tests e2e fixtures node_modules
# dist coverage .stryker-tmp*. Deleted files are never mutated.
#
# Output — KEY=VALUE lines on stdout: config_path, report_path, temp_dir, test_runner,
# coverage_analysis, ignore_static, scope_mode (changed-lines|whole-files), diff_base (<ref>@<sha7>|
# none), file_count, mutate_count (entries), mutated_lines, changed_lines (<n>|unknown),
# dropped_count, one dropped_file=<reason>:<path> per file left out (reason: unchanged | not-source |
# glob-path); for the vitest runner vitest_config (repo-relative, or none), vitest_root,
# vitest_include_source (explicit|colocated|workspace-include), vitest_include_count (<n>|unknown)
# and one vitest_include=<glob> per glob, Vitest-root-relative; then run_command, which runs Stryker
# under stryker-run-watchdog.sh (exit 124 = no progress for --no-progress-timeout s). Plus ONE summary
# line on stderr that repeats the vitest_* values.
#
# Vitest: the config nearest each scoped file (or --vitest-config); covering tests = --test-file/
# --tests-from, else co-located foo.test|spec.* / __tests__/foo.*, else the config's own include.
#
# Exit codes: 0 ok · 1 --vitest-config does not exist · 2 usage error · 3 no such file, a path
#             outside --repo, or nothing left to mutate · 4 cannot compute the diff (not a git work
#             tree, no base found) · 5 no single Vitest config fits the scope: the files belong to
#             2+ configs (one `vitest_group=<config|none> -> <file>,<file>` line per config), or only
#             to a multi-project config — test.projects/test.workspace or a vitest.workspace.* — (one
#             `vitest_aggregator=<config>` line, then one `vitest_group=<workspace dir> -> <files>` per
#             workspace). Nothing is written.
set -uo pipefail

REPO=""
OUT=""
REPORT=""
RUNNER=""
CONCURRENCY="4"
COVERAGE=""
TIMEOUT_MS="60000"
IDLE_TIMEOUT="600"
DRY_RUN_MIN="5"
PRINT_CONFIG=0
DIFF_BASE=""
WHOLE_FILES=0
INCLUDE_STATIC=0
FILES_FLAG=0
FILES=()
VITEST_CONFIG=""
TESTS_FLAG=0
TESTS=()

die() { echo "$1" >&2; exit "${2:-2}"; }

# Every value-taking flag proves its value exists BEFORE `shift 2`. With a trailing valueless flag,
# `shift 2` on one remaining arg fails WITHOUT consuming it, so `while [ $# -gt 0 ]` re-enters on
# the same token forever — a silent infinite loop instead of the documented exit 2. Reproduced on
# bash 3.2 in review; it spins with no output until something kills it.
need_val() { [ "$1" -ge 2 ] || die "missing value for $2"; }

# Append every non-empty line of list file $1 to the array named $2 (FILES or TESTS).
# `|| [ -n "$_l" ]` catches a final line with no trailing newline: `read` returns non-zero there and
# the loop body would never run for it, silently scoping the run to N-1 entries — which Stryker
# reports as a perfectly successful smaller run.
append_from() {
  local _l
  [ ! -d "$1" ] && [ -r "$1" ] || die "--$3: no such file: $1"
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l="${_l%$'\r'}"  # a CRLF list would otherwise name files ending in a carriage return
    [ -n "$_l" ] || continue
    case "$2" in FILES) FILES+=("$_l") ;; TESTS) TESTS+=("$_l") ;; *) die "append_from: unknown list $2" ;; esac
  done < "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)        need_val $# "$1"; FILES_FLAG=1; FILES+=("$2"); shift 2 ;;
    --files-from)  need_val $# "$1"; FILES_FLAG=1; append_from "$2" FILES files-from; shift 2 ;;
    --test-file)   need_val $# "$1"; TESTS_FLAG=1; TESTS+=("$2"); shift 2 ;;
    --tests-from)  need_val $# "$1"; TESTS_FLAG=1; append_from "$2" TESTS tests-from; shift 2 ;;
    --vitest-config) need_val $# "$1"; [ -n "$2" ] || die "--vitest-config: empty path"; VITEST_CONFIG="$2"; shift 2 ;;
    --diff)        need_val $# "$1"; DIFF_BASE="$2"; shift 2 ;;
    --whole-files) WHOLE_FILES=1; shift ;;
    --include-static) INCLUDE_STATIC=1; shift ;;
    --repo)        need_val $# "$1"; REPO="$2"; shift 2 ;;
    --out)         need_val $# "$1"; OUT="$2"; shift 2 ;;
    --report)      need_val $# "$1"; REPORT="$2"; shift 2 ;;
    --runner)      need_val $# "$1"; RUNNER="$2"; shift 2 ;;
    --concurrency) need_val $# "$1"; CONCURRENCY="$2"; shift 2 ;;
    --coverage)    need_val $# "$1"; COVERAGE="$2"; shift 2 ;;
    --timeout-ms)  need_val $# "$1"; TIMEOUT_MS="$2"; shift 2 ;;
    --no-progress-timeout) need_val $# "$1"; IDLE_TIMEOUT="$2"; shift 2 ;;
    --dry-run-timeout-min) need_val $# "$1"; DRY_RUN_MIN="$2"; shift 2 ;;
    --print-config) PRINT_CONFIG=1; shift ;;
    -h|--help)     awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *)             die "unknown argument: $1" ;;
  esac
done

# A list the caller asked for but that holds nothing is a broken caller, not "use the default".
# Falling through to the whole-branch diff here would mutate files the caller never named.
if [ "$FILES_FLAG" = 1 ] && [ "${#FILES[@]}" -eq 0 ]; then
  die "--file/--files-from given but the list is empty — refusing to guess a scope"
fi
if [ "$TESTS_FLAG" = 1 ] && [ "${#TESTS[@]}" -eq 0 ]; then
  die "--test-file/--tests-from given but the list is empty — refusing to fall back to other tests"
fi

[ -n "$DIFF_BASE" ] && case "$DIFF_BASE" in -*) die "--diff: base must be a ref, got option-like '$DIFF_BASE'" ;; esac

# Decision 3. The default pairs `ignoreStatic: true` with `perTest` because Stryker rejects
# ignoreStatic under any other coverage mode at startup — after the farm already paid for the
# sync and the queue. Refuse that combination here, where it costs nothing.
if [ -z "$COVERAGE" ]; then
  if [ "$INCLUDE_STATIC" = 1 ]; then COVERAGE="off"; else COVERAGE="perTest"; fi
fi
case "$COVERAGE" in off|all|perTest) ;; *) die "--coverage must be off|all|perTest" ;; esac
if [ "$INCLUDE_STATIC" = 0 ] && [ "$COVERAGE" != "perTest" ]; then
  die "--coverage $COVERAGE cannot be combined with ignoreStatic (the default): Stryker refuses to start unless coverageAnalysis is perTest. Add --include-static to run static mutants under --coverage $COVERAGE."
fi
[[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || die "--concurrency must be an integer"
[[ "$TIMEOUT_MS" =~ ^[0-9]{1,9}$ ]] || die "--timeout-ms must be an integer (at most 9 digits)"
[[ "$IDLE_TIMEOUT" =~ ^[1-9][0-9]{0,8}$ ]] || die "--no-progress-timeout must be an integer >= 1 (seconds)"
[[ "$DRY_RUN_MIN" =~ ^[1-9][0-9]{0,5}$ ]] || die "--dry-run-timeout-min must be an integer >= 1 (minutes)"
# Stryker prints nothing during its initial test run, and one mutant may legitimately take timeoutMS:
# an idle limit below either aborts healthy runs with 124.
if [ "$IDLE_TIMEOUT" -le $((DRY_RUN_MIN * 60)) ]; then
  echo "stryker-scoped-config: WARNING --no-progress-timeout $IDLE_TIMEOUT s is not longer than the silent initial test run (--dry-run-timeout-min $DRY_RUN_MIN = $((DRY_RUN_MIN * 60)) s): a healthy run can be aborted" >&2
fi
if [ $((IDLE_TIMEOUT * 1000)) -le "$TIMEOUT_MS" ]; then
  echo "stryker-scoped-config: WARNING --no-progress-timeout $IDLE_TIMEOUT s is not longer than one mutant's timeout floor (--timeout-ms $TIMEOUT_MS; Stryker adds timeoutFactor x the test time on top): a slow mutant can be aborted as 'no progress'" >&2
fi
command -v node >/dev/null 2>&1 || die "node is required (StrykerJS is a node tool) and was not found on PATH"

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
REPO="$(cd "$REPO" && pwd)" || die "--repo: no such directory"

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
if [ "$TEST_RUNNER" != vitest ] && { [ -n "$VITEST_CONFIG" ] || [ "$TESTS_FLAG" = 1 ]; }; then
  die "--vitest-config/--test-file/--tests-from apply to the vitest runner only (runner: $TEST_RUNNER)"
fi
# No lib, no honest config: falling back to the repo-root guess is exactly what RD-121 removed.
SELF="$0"; [ -L "$SELF" ] && { _t="$(readlink -- "$SELF")"; case "$_t" in /*) SELF="$_t" ;; *) SELF="$(dirname -- "$SELF")/$_t" ;; esac; }
SELF_DIR="$(cd "$(dirname -- "$SELF")" && pwd)"
VITEST_LIB="$SELF_DIR/lib/stryker-vitest.cjs"
WATCHDOG_SRC="$SELF_DIR/stryker-run-watchdog.sh"
[ -f "$WATCHDOG_SRC" ] || die "missing $WATCHDOG_SRC — run_command must go through it, and it ships beside $(basename "$0")"
if [ "$TEST_RUNNER" = vitest ] && [ ! -f "$VITEST_LIB" ]; then
  die "missing $VITEST_LIB — the vitest runner needs the lib/ that ships beside $(basename "$0")"
fi


# Normalize the scope set to repo-relative POSIX paths and verify each one exists. A typo here
# is the difference between "0 mutants, score 100%" and a real measurement, and Stryker reports
# an empty mutate set as a successful run.
# Containment is checked on the RESOLVED absolute path, for EVERY input, with no fast path.
# The first version trusted `[ -f "$REPO/$f" ]` alone for repo-relative input — but
# `$REPO/../../etc/hosts` is a file that exists, so `--file ../../../../etc/hosts` passed the
# check and landed verbatim in the generated `mutate` array. On this workstation the sibling
# directories under the parent are other production repos, so a single crafted or mistaken entry
# scoped a mutation run at code outside the repo entirely.
# The physical check catches a symlinked directory inside the repo that points outside it; the
# printed path stays the logical one the caller used.
REPO_PHYS="$(cd "$REPO" && pwd -P)"
resolve_in_repo() {  # $1 = a path as given; prints it repo-relative. Returns 4: missing, 3: outside/refused
  local f="$1" cand abs phys
  case "$f" in *$'\n'*) echo "path holds a newline, refused: $f" >&2; return 3 ;; esac
  if [ -f "$REPO/$f" ]; then
    cand="$REPO/$f"
  elif [ -f "$f" ]; then
    cand="$f"
  else
    echo "no such file: $f" >&2; return 4
  fi
  abs="$(cd "$(dirname -- "$cand")" && pwd)/$(basename -- "$cand")"
  phys="$(cd "$(dirname -- "$cand")" && pwd -P)/"
  # A symlinked FILE: follow the whole chain (a -> b -> /outside) to where the content really is.
  local tgt="$cand" hops=0
  while [ -L "$tgt" ] && [ "$hops" -lt 40 ]; do
    local next; next="$(readlink -- "$tgt")"
    case "$next" in /*) tgt="$next" ;; *) tgt="$(dirname -- "$tgt")/$next" ;; esac
    hops=$((hops + 1))
  done
  [ -L "$tgt" ] && { echo "symlink chain too deep, refused: $f" >&2; return 3; }
  [ "$tgt" = "$cand" ] || phys="$(cd "$(dirname -- "$tgt")" 2>/dev/null && pwd -P)/"
  case "$abs" in "$REPO"/*) ;; *) echo "file resolves outside --repo ($REPO): $f -> $abs" >&2; return 3 ;; esac
  case "$phys" in "$REPO_PHYS"/*) ;; *) echo "file resolves outside --repo ($REPO) through a symlink: $f -> $phys" >&2; return 3 ;; esac
  printf '%s\n' "${abs#"$REPO"/}"
}
REL_FILES=()
for f in ${FILES[@]+"${FILES[@]}"}; do
  rel="$(resolve_in_repo "$f")" || exit 3
  REL_FILES+=("$rel")
done
REL_TESTS=()
for f in ${TESTS[@]+"${TESTS[@]}"}; do
  rel="$(resolve_in_repo "$f")" || exit 3
  REL_TESTS+=("$rel")
done
# A config path that does not exist is the caller's typo, not "resolve one for me": exit 1, named.
REL_VITEST_CONFIG=""
if [ -n "$VITEST_CONFIG" ]; then
  REL_VITEST_CONFIG="$(resolve_in_repo "$VITEST_CONFIG")"; rc=$?
  [ "$rc" = 4 ] && die "--vitest-config: no such file: $VITEST_CONFIG (relative to --repo $REPO or the current directory)" 1
  [ "$rc" = 0 ] || exit 3
fi

# ── scope + config emission ─────────────────────────────────────────────────
# One node program computes the scope from git (decision 6), writes the config and prints the
# KEY=VALUE contract. Paths travel as separate argv entries, never through a shell string.
# The explicit tests travel as ONE newline-joined entry (resolve_in_repo refuses a newline in a path):
# the variadic tail is the scope list, and a second list there could not be told apart from it.
TESTS_JOINED="$(printf '%s\n' ${REL_TESTS[@]+"${REL_TESTS[@]}"})"
node - "$REPO" "$OUT" "$REPORT" "$TEST_RUNNER" "$COVERAGE" "$CONCURRENCY" "$TIMEOUT_MS" \
  "$INCLUDE_STATIC" "$WHOLE_FILES" "$FILES_FLAG" "$DIFF_BASE" "$PRINT_CONFIG" "$$" \
  "$REL_VITEST_CONFIG" "$TESTS_JOINED" "$VITEST_LIB" "$IDLE_TIMEOUT" "$DRY_RUN_MIN" "$WATCHDOG_SRC" \
  ${REL_FILES[@]+"${REL_FILES[@]}"} <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const crypto = require('crypto');

const [repo, outArg, reportArg, runner, coverage, concurrency, timeoutMs, includeStaticArg,
  wholeFilesArg, filesFlagArg, diffBaseArg, printConfigArg, shellPid, vitestConfigArg, testsArg,
  vitestLib, idleTimeout, dryRunMin, watchdogSrc, ...rawFiles] = process.argv.slice(2);
const explicitTests = [...new Set(testsArg.split('\n').filter(Boolean))];
const givenFiles = [...new Set(rawFiles)];
const includeStatic = includeStaticArg === '1';
const wholeFiles = wholeFilesArg === '1';
const filesGiven = filesFlagArg === '1';
const ME = 'stryker-scoped-config';

const say = (msg) => process.stderr.write(`${ME}: ${msg}\n`);
const fail = (code, msg) => { say(msg); process.exit(code); };

// ── git ──
function git(args, { allowFail = false } = {}) {
  const r = cp.spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 1 << 30 });
  if (r.error || r.status !== 0) {
    if (allowFail) return null;
    fail(4, `git ${args.join(' ')} failed: ${(r.stderr || String(r.error || '')).trim()}`);
  }
  return r.stdout;
}
const isGit = () => (git(['rev-parse', '--is-inside-work-tree'], { allowFail: true }) || '').trim() === 'true';
const refExists = (ref) => git(['rev-parse', '--verify', '--quiet', `${ref}^{commit}`], { allowFail: true }) !== null;

// Decision 6, base: the NEAREST default branch (see header). Remote-tracking refs first — a local
// main carrying unpushed commits would otherwise be the nearest base and hide exactly those commits.
function resolveBase() {
  if (!refExists('HEAD')) fail(4, 'HEAD has no commit yet — nothing to diff against; pass --whole-files --file <path>');
  let candidates = [];
  if (diffBaseArg) {
    if (!refExists(diffBaseArg)) fail(4, `--diff: '${diffBaseArg}' does not resolve to a commit`);
    candidates = [diffBaseArg];
  } else {
    const remotes = (git(['remote'], { allowFail: true }) || '').split('\n').filter(Boolean)
      .sort((a, b) => (a === 'origin' ? -1 : b === 'origin' ? 1 : 0));
    for (const r of remotes) {
      const head = git(['symbolic-ref', '--quiet', '--short', `refs/remotes/${r}/HEAD`], { allowFail: true });
      if (head && head.trim()) candidates.push(head.trim());
      for (const b of ['develop', 'main', 'master']) {
        if (refExists(`refs/remotes/${r}/${b}`)) candidates.push(`${r}/${b}`);
      }
    }
    if (!candidates.length) {
      const current = (git(['symbolic-ref', '--quiet', '--short', 'HEAD'], { allowFail: true }) || '').trim();
      for (const b of ['develop', 'main', 'master']) {
        if (b !== current && refExists(`refs/heads/${b}`)) candidates.push(b);
      }
    }
    candidates = [...new Set(candidates)];
    if (!candidates.length) {
      fail(4, 'no default branch found (no <remote>/HEAD, develop, main or master other than the current branch) — pass --diff <base>');
    }
  }
  let best = null;
  for (const ref of candidates) {
    const mb = git(['merge-base', 'HEAD', ref], { allowFail: true });
    if (!mb || !mb.trim()) continue;
    const sha = mb.trim();
    const dist = Number((git(['rev-list', '--count', `${sha}..HEAD`]) || '0').trim());
    if (!best || dist < best.dist) best = { ref, sha, dist };
  }
  if (!best) fail(4, `no merge-base between HEAD and ${candidates.join(', ')} — pass --diff <base>`);
  return best;
}

// ── mutable-file filter ──
const MUTABLE_EXT = new Set(['.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.mts', '.cts', '.vue', '.svelte']);
const NON_PROD_DIRS = new Set(['__tests__', '__mocks__', '__fixtures__', 'test', 'tests', 'e2e',
  'fixtures', 'node_modules', 'dist', 'coverage']);
function whyNotMutable(p) {
  const base = path.posix.basename(p);
  if (!MUTABLE_EXT.has(path.posix.extname(base))) return 'not a mutable source extension';
  if (/\.d\.[cm]?ts$/.test(base)) return 'type declarations';
  if (/\.(test|spec|stories|config)\.[^.]+$/.test(base)) return 'test/spec/story/config file';
  if (base.startsWith('.stryker-scoped-')) return 'generated by this script';
  const dirs = p.split('/').slice(0, -1);
  const hit = dirs.find((d) => NON_PROD_DIRS.has(d) || d.startsWith('.stryker-tmp'));
  if (hit) return `under ${hit}/`;
  return null;
}

// Stryker matches `mutate` entries with minimatch and REFUSES a line range on a glob path. Next.js
// `app/[id]/page.tsx` is such a path (and as a glob matches `app/i/page.tsx`): a whole-file entry
// is escaped char-class style; a range on it is impossible, so a modified one is dropped (below).
const rangeUnsafe = (p) => /[*?[\]]/.test(p) || /[+@!]\(/.test(p) || /\{[^}]*(,|\.\.)[^}]*\}/.test(p);
const escapeGlob = (p) => p.replace(/[*?[\]{}()]/g, (c) => `[${c}]`);

function countLines(rel) {
  let buf;
  try { buf = fs.readFileSync(path.join(repo, rel)); } catch { return 0; }
  if (!buf.length) return 0;
  let n = 0;
  for (const byte of buf) if (byte === 10) n++;
  return buf[buf.length - 1] === 10 ? n : n + 1;
}

// git C-quotes a path holding `"`, `\` or control characters even with core.quotePath=false.
function unquote(s) {
  if (!s.startsWith('"')) return s;
  const body = s.slice(1, s.lastIndexOf('"'));
  const bytes = [];
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c !== '\\') { bytes.push(...Buffer.from(c, 'utf8')); continue; }
    const n = body[++i];
    if (/[0-7]/.test(n)) { bytes.push(parseInt(body.substr(i, 3), 8)); i += 2; continue; }
    const map = { n: 10, t: 9, r: 13, a: 7, b: 8, f: 12, v: 11, '"': 34, '\\': 92 };
    bytes.push(map[n] !== undefined ? map[n] : n.charCodeAt(0));
  }
  return Buffer.from(bytes).toString('utf8');
}

// Map<relPath, {added, ranges:[[s,e]]}> from `git diff -U0 <base>` against the WORKING TREE plus
// untracked files. Hunk bodies are skipped by the header's line COUNTS, not by prefix: an added line
// `++ b/evil.ts` prints as `+++ b/evil.ts` and would otherwise read as the next file's header.
function changedRanges(baseSha) {
  const raw = git(['-c', 'core.quotePath=false', '-c', 'diff.renames=true', 'diff', '-U0', '--no-color',
    '--no-ext-diff', '--no-textconv', '--relative', '-M', '--diff-filter=AMR', '--src-prefix=a/',
    '--dst-prefix=b/', baseSha, '--']);
  const files = new Map();
  const lines = raw.split('\n');
  let cur = null;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith('diff --git ')) { cur = { path: null, added: false, ranges: [] }; continue; }
    if (!cur) continue;
    if (l.startsWith('--- ')) { if (l === '--- /dev/null') cur.added = true; continue; }
    if (l.startsWith('+++ ')) {
      // git appends a TAB to an unquoted path holding a space; left on, `x y.ts\t` is not a .ts file.
      const field = l.slice(4);
      const p = field.startsWith('"') ? unquote(field) : field.replace(/\t$/, '');
      if (p !== '/dev/null') { cur.path = p.replace(/^b\//, ''); files.set(cur.path, cur); }
      continue;
    }
    const m = /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(l);
    if (m) {
      let oldN = m[1] === undefined ? 1 : Number(m[1]);
      let newN = m[3] === undefined ? 1 : Number(m[3]);
      const start = Number(m[2]);
      if (newN > 0) cur.ranges.push([start, start + newN - 1]);
      while ((oldN > 0 || newN > 0) && i + 1 < lines.length) {
        const c = lines[++i][0];
        if (c === '-') oldN--; else if (c === '+') newN--; else if (c !== '\\') { i--; break; }
      }
    }
  }
  // A local run's sandbox (`.stryker-tmp-<tag>/`, often not ignored) must not count as added files.
  const untracked = (git(['-c', 'core.quotePath=false', 'ls-files', '-z', '--others', '--exclude-standard',
    '--exclude=.stryker-tmp*', '--exclude=node_modules'], { allowFail: true }) || '').split('\0').filter(Boolean);
  for (const p of untracked) {
    const n = countLines(p);
    files.set(p, { path: p, added: true, ranges: n ? [[1, n]] : [] });
  }
  for (const [p, f] of files) if (!f.ranges.length) files.delete(p);
  return files;
}

// ── scope ──
let base = null;
let changed = null;           // Map of mutable changed files, or null when not computable
const entries = [];           // the `mutate` array
const scopedFiles = new Set();
let mutatedLines = 0;
const dropped = [];           // [reason, path] — every file left out, reported on stdout AND stderr

if (wholeFiles && filesGiven) {
  // The explicit opt-out, git or no git; the diff (when computable) only prices it in lines.
  if (isGit()) {
    base = resolveBase();
    changed = changedRanges(base.sha);
  }
} else {
  if (!isGit()) {
    fail(4, `${repo} is not a git work tree — the default scope is the CHANGED LINES and there is no diff to take them from. ` +
      'Pass --whole-files --file <path> to mutate whole files deliberately.');
  }
  base = resolveBase();
  changed = changedRanges(base.sha);
}

let changedLines = null;
let skippedNonMutable = 0;
const mutableChanged = new Map();
if (changed) {
  changedLines = 0;
  for (const [p, f] of changed) {
    if (whyNotMutable(p)) { skippedNonMutable++; continue; }
    mutableChanged.set(p, f);
    for (const [s, e] of f.ranges) changedLines += e - s + 1;
  }
}
const baseLabel = base ? `${base.ref}@${base.sha.slice(0, 7)}` : 'none';

function addWhole(p) {
  entries.push(rangeUnsafe(p) ? escapeGlob(p) : p);
  scopedFiles.add(p);
  mutatedLines += countLines(p);
}
function addRanges(p, f) {
  if (f.added) { addWhole(p); return; }
  if (rangeUnsafe(p)) {
    say(`DROPPED ${p}: changed, but Stryker refuses a line range on a glob path — cover its changed ` +
      `lines with the LLM engine, or (user request) --whole-files --file '${p}'.`);
    dropped.push(['glob-path', p]);
    return;
  }
  for (const [s, e] of f.ranges) { entries.push(`${p}:${s}-${e}`); mutatedLines += e - s + 1; }
  scopedFiles.add(p);
}

if (wholeFiles) {
  const list = filesGiven ? givenFiles : [...mutableChanged.keys()];
  say('WARNING --whole-files: every line of every file below is mutated, changed or not. This is NOT the default: ' +
    'on 2026-10-02 a whole-file campaign mutated 33,367 lines (204 files, 97 untouched by the branch) to test 2,880 changed ones and ran 15+ hours.');
  if (changed && filesGiven) {
    const unchanged = list.filter((p) => !changed.has(p));
    if (unchanged.length) {
      say(`WARNING --whole-files: ${unchanged.length} of ${list.length} listed files are UNCHANGED vs ${baseLabel} and will be mutated anyway:`);
      for (const p of unchanged) say(`  unchanged: ${p}`);
    }
  }
  for (const p of list) addWhole(p);
} else if (filesGiven) {
  const listed = [];
  for (const p of givenFiles) {
    const why = whyNotMutable(p);
    if (why) { listed.push(['not-source', p, why]); continue; }
    const f = changed.get(p);
    if (!f) { listed.push(['unchanged', p, `unchanged vs ${baseLabel}`]); continue; }
    addRanges(p, f);
  }
  if (listed.length) {
    say(`DROPPED ${listed.length} of ${givenFiles.length} listed files — only lines this branch changed or added ` +
      'are mutated (--whole-files mutates them anyway, on user request):');
    for (const [reason, p, why] of listed) { say(`  dropped: ${p} (${why})`); dropped.push([reason, p]); }
  }
  const others = [...mutableChanged.keys()].filter((p) => !givenFiles.includes(p)).length;
  if (others) say(`note: ${others} other changed files are outside the given list and are not mutated`);
} else {
  for (const [p, f] of mutableChanged) addRanges(p, f);
}

if (!entries.length) {
  const why = wholeFiles ? 'no files to mutate'
    : filesGiven ? `none of the listed files has mutable changed lines vs ${baseLabel}`
      : `no mutable changed lines vs ${baseLabel}${dropped.length ? ` (${dropped.length} glob-path files dropped)` : ''}` +
        ' — on the default branch itself, pass --diff <ref> for the commits to mutate';
  fail(3, `${why}. Nothing to mutate, no config written (an empty mutate set scores 100% for nothing).`);
}

// A tag that is unique per invocation AND per scope, so two scoped runs on one box never share a
// sandbox. Decision 2: `.stryker-tmp` is the default for every run in the repo.
const tag = `${crypto.createHash('sha1').update(entries.join('\n')).digest('hex').slice(0, 10)}-${shellPid}`;
const out = outArg || path.join(repo, `.stryker-scoped-${tag}.conf.json`);
const report = reportArg || path.join(repo, `.stryker-scoped-${tag}.report.json`);
const tempDir = `.stryker-tmp-${tag}`;

// Decided BEFORE anything is written, so a refusal (exit 5) leaves nothing behind.
let vitest = null;
let vlib = null;
// Beside the Stryker config, in the repo tree: Stryker never copies its tempDirName into the sandbox,
// so a config under <temp_dir> would not exist where the runner looks for it (RD-121 evidence 1).
const vitestConfigFile = `.stryker-scoped-${tag}.vitest.config.mts`;
// In the repo, not the plugin: `rt` ships the repo to the farm, and run_command must work there.
const watchdogFile = `.stryker-scoped-${tag}.watchdog.sh`;
if (runner === 'vitest') {
  vlib = require(vitestLib);
  const r = vlib.resolveVitest({ repo, files: [...scopedFiles], override: vitestConfigArg || null,
    tests: explicitTests });
  if (r.error) fail(2, r.error);
  if (r.groups) {
    say(r.aggregator
      ? `${r.aggregator} is a multi-project (test.projects/workspace) config: no include can narrow it. Run one campaign per ` +
        'workspace below, each with --vitest-config <that workspace\'s config> (or give the workspace its own config).'
      : `the scoped files belong to ${r.groups.length} different Vitest configs — run one campaign per group:`);
    for (const g of r.groups) say(`  ${g.key} -> ${g.files.join(', ')}`);
    process.stdout.write((r.aggregator ? `vitest_aggregator=${r.aggregator}\n` : '') +
      r.groups.map((g) => `vitest_group=${g.key} -> ${g.files.join(',')}\n`).join(''));
    process.exit(5);
  }
  for (const w of r.warnings) say(`WARNING ${w}`);
  const known = r.include || r.printed;
  const printed = known || [`<inherited from ${r.config}>`];
  vitest = { ...r, printed, count: known ? known.length : 'unknown' };
}

// Resolve runner-config candidates against the REPO, never against CWD: this script is routinely
// invoked from somewhere else, and a CWD-relative existsSync silently reports "no jest config"
// for a project that has one — which drops the transform and fails at startup.
const inRepo = (f) => fs.existsSync(path.join(repo, f));

const cfg = {
  $schema: 'https://raw.githubusercontent.com/stryker-mutator/stryker-js/master/packages/api/schema/stryker-core.json',
  _generatedBy: 'zuvo scripts/stryker-scoped-config.sh — scoped run, do not commit',
  // Note `mutate` here is the FULL scope, not a CLI override: decision 1. Everything the project
  // config would otherwise contribute (repo-wide mutate array, its reporters, its tempDirName) is
  // deliberately absent — this file is the whole configuration for this run. Entries are
  // `file:startLine-endLine` per changed hunk (decision 6), or a bare path for a whole file.
  mutate: entries,
  testRunner: runner,
  // Decision 3: perTest + ignoreStatic by default; --include-static restores `off`.
  coverageAnalysis: coverage,
  ignoreStatic: !includeStatic,
  // progress-append-only is the watchdog's heartbeat: a moving "tested" counter is progress.
  reporters: ['json', 'clear-text', 'progress-append-only'],
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
  dryRunTimeoutMinutes: Number(dryRunMin),
};

if (runner === 'jest') {
  // next/jest and ts-jest both build their config through a loader, so pointing Stryker at a
  // raw config object loses the transform. `projectType: custom` + configFile keeps the
  // project's own resolution intact.
  const candidates = ['jest.config.js', 'jest.config.ts', 'jest.config.mjs', 'jest.config.cjs', 'jest.config.json'];
  const found = candidates.find(inRepo);
  cfg.jest = { projectType: 'custom', enableFindRelatedTests: coverage !== 'off' };
  if (found) cfg.jest.configFile = found;
} else if (runner === 'vitest') {
  // vitest.related stays at its default: Stryker narrows each mutant's run to the related tests.
  cfg.vitest = { configFile: vitestConfigFile };
} else if (runner === 'command') {
  // `npm test` with no file filter: correct everywhere, slowest. Override with --runner once the
  // project's real runner plugin is installed.
  cfg.commandRunner = { command: 'npm test' };
}

const runFiles = [watchdogFile, vitestConfigFile, path.relative(repo, out), path.relative(repo, report)]
  .filter((f) => !f.startsWith('..'));
const ignored = isGit() ? runFiles.filter((f) => git(['check-ignore', '-q', f], { allowFail: true }) !== null) : [];
if (ignored.length) {
  say(`WARNING git-ignored: ${ignored.join(', ')} — rt syncs only non-ignored files, so a farm run would not see ` +
    'them. Run locally, or un-ignore .stryker-scoped-*.');
}

// All or nothing: a refused write must not leave half a run behind (a config that names a missing file).
const written = [];
// Only files this run creates are rolled back: an --out that already existed is never deleted.
const write = (file, body) => { if (!fs.existsSync(file)) written.push(file); fs.writeFileSync(file, body); };
try {
  if (vitest) {
    write(path.join(repo, vitestConfigFile),
      vlib.renderVitestConfig({ config: vitest.config, root: vitest.root, include: vitest.include }));
  }
  write(path.join(repo, watchdogFile), fs.readFileSync(watchdogSrc));
  write(out, JSON.stringify(cfg, null, 2) + '\n');
} catch (e) {
  for (const f of written) { try { fs.unlinkSync(f); } catch { /* already gone */ } }
  fail(2, `failed to write ${e.path || out}: ${e.message}`);
}

const rangeCount = entries.filter((e) => /:\d+-\d+$/.test(e)).length;
const pct = changedLines ? ` (${Math.round((100 * mutatedLines) / changedLines)}% of changed)` : '';
say(`scope=${wholeFiles ? 'WHOLE-FILES' : 'changed-lines'} base=${baseLabel} files=${scopedFiles.size} ` +
  `line_ranges=${rangeCount} whole_files=${entries.length - rangeCount} mutated_lines=${mutatedLines} ` +
  `changed_lines=${changedLines === null ? 'unknown' : changedLines}${pct} ignoreStatic=${!includeStatic}` +
  (changed ? ` skipped_non_source=${skippedNonMutable}` : '') + ` dropped=${dropped.length}` +
  (vitest ? ` vitest_config=${vitest.config} vitest_root=${vitest.root} vitest_include_source=${vitest.source} ` +
    `vitest_include_count=${vitest.count} vitest_include=${vitest.printed.join(' ')}` : ''));

// run_command is handed to a shell: quote a path only when it needs it, so plain paths read as before.
const shq = (p) => (/^[\w@%+=:,./][\w@%+=:,./-]*$/.test(p) ? p : `'${p.replace(/'/g, "'\\''")}'`);
const kv = [
  ['config_path', out],
  ['report_path', report],
  ['temp_dir', tempDir],
  ['test_runner', runner],
  ['coverage_analysis', coverage],
  ['ignore_static', String(!includeStatic)],
  ['scope_mode', wholeFiles ? 'whole-files' : 'changed-lines'],
  ['diff_base', baseLabel],
  ['file_count', scopedFiles.size],
  ['mutate_count', entries.length],
  ['mutated_lines', mutatedLines],
  ['changed_lines', changedLines === null ? 'unknown' : changedLines],
  // On stdout, not only stderr: callers capture stdout, and a dropped CHANGED file is a coverage gap.
  ['dropped_count', dropped.length],
  ...dropped.map(([reason, p]) => ['dropped_file', `${reason}:${p}`]),
  // Printed BEFORE run_command: the caller sees which config and which tests the run admits.
  ...(vitest ? [['vitest_config', vitest.config], ['vitest_root', vitest.root],
    ['vitest_include_source', vitest.source], ['vitest_include_count', vitest.count],
    ...vitest.printed.map((g) => ['vitest_include', g]),
    // workspace-include is all-or-nothing: these files are why the narrowing was given up.
    ...(vitest.missing || []).map((f) => ['vitest_missing_tests', f])] : []),
  // The CWD is pinned on purpose: `mutate` entries are repo-relative and Stryker resolves them
  // against the RUN's working directory. This script is routinely invoked from elsewhere, and a
  // command run from the wrong directory matches zero files — which Stryker reports as a successful
  // 100% run, the exact silent failure the scope validation above exists to prevent.
  ['run_command', `(cd ${shq(repo)} && bash ./${watchdogFile} --idle-timeout ${idleTimeout} -- npx stryker run ${shq(out)})`],
];
process.stdout.write(kv.map(([k, v]) => `${k}=${v}\n`).join(''));
if (printConfigArg === '1') process.stdout.write('--- config ---\n' + fs.readFileSync(out, 'utf8'));
NODE
rc=$?
case "$rc" in
  0|2|3|4|5) exit "$rc" ;;
  *) die "scope/config step failed (node exited $rc)" 2 ;;
esac
