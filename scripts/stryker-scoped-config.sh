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
#   3. Static (module-level) mutants are IGNORED by default (`ignoreStatic: true`). They run at
#      import time, so per-test coverage cannot attribute them: under `coverageAnalysis: perTest`
#      they are mismarked SURVIVED, and running them honestly means the WHOLE suite with a fresh
#      module environment per mutant. Measured 2026-10-02: Stryker itself warned that static
#      mutants took 71–83% of a farm campaign's run time. Stryker accepts `ignoreStatic` ONLY with
#      `coverageAnalysis: perTest` (any other value is a startup error), so that is the default.
#      `--include-static` opts out and restores the old static-safe setup (`coverageAnalysis: off`).
#   4. The report has to land somewhere the caller can actually read afterwards — especially when
#      the run is sent to the farm, where the sandbox is discarded.
#   5. next/jest and vitest need different runner wiring, and the wrong one fails at startup with
#      an error that names the test framework, not the config.
#   6. The scope is the CHANGED LINES, not the changed files — and never unchanged files. Measured
#      2026-10-02: one campaign built with `--files-from` mutated 204 whole files = 33,367 lines,
#      while its branch had added or changed 2,880 of them (8%); 97 of the 204 files were not
#      changed by the branch at all. It ran for 15+ hours on the farm to answer a question about
#      2,880 lines. So the default emits one Stryker line range (`file:start-end`) per diff hunk,
#      an added file is mutated whole (every line is new), and a `--file`/`--files-from` list is
#      INTERSECTED with the diff: unchanged files are dropped (named on stderr), changed ones are
#      narrowed to their hunks. Whole-file mutation needs `--whole-files`, which says why it is not
#      the default every time it is used.
#
# This script makes those decisions once, from the project's own manifests and git history, and
# prints the path to a config file you pass POSITIONALLY: `npx stryker run <config>`.
#
# Usage:
#   stryker-scoped-config.sh [options]                          # the lines this branch changed
#   stryker-scoped-config.sh --diff <base> [options]            # ... vs merge-base(HEAD, <base>)
#   stryker-scoped-config.sh --file <path> [--file <path> ...]  # those files ∩ the diff
#   stryker-scoped-config.sh --files-from <list-file>           # same, from a list
#   stryker-scoped-config.sh --whole-files --file <path> ...    # OPT-OUT: whole files, changed or not
#
# Base (when --diff is not given): the merge-base of HEAD with the NEAREST default branch —
# origin/HEAD and <remote>/{develop,main,master}, falling back to local develop/main/master. The
# nearest one is the one with the fewest commits between the merge-base and HEAD, so a branch cut
# from develop in a repo whose origin/HEAD is main is still diffed against develop. The diff is
# taken against the WORKING TREE, so committed, staged and unstaged changes all count, and
# untracked (not ignored) files count as added.
#
# Options:
#   --diff <base>         diff against merge-base(HEAD, <base>) instead of the detected default
#   --whole-files         mutate whole files (the listed ones, else every changed one) — NOT the default
#   --include-static      do not ignore static mutants; implies --coverage off unless given
#   --repo <dir>          project root (default: git toplevel of CWD, else CWD). A subdirectory of
#                         a git repo (monorepo package) scopes the diff to it, paths relative to it.
#   --out <path>          where to write the config (default: <repo>/.stryker-scoped-<tag>.conf.json)
#   --report <path>       JSON report path (default: <repo>/.stryker-scoped-<tag>.report.json)
#   --runner <name>       jest|vitest|mocha|command — default: detected
#   --concurrency <n>     default: 4 (farm-safe; a native run is the heaviest thing this repo starts)
#   --coverage <mode>     off|all|perTest — default: perTest (off with --include-static); see decision 3
#   --timeout-ms <n>      default: 60000
#   --print-config        also echo the generated JSON to stdout
#
# Mutable files: .js .jsx .ts .tsx .mjs .cjs .mts .cts .vue .svelte, minus *.d.ts, *.test.*,
# *.spec.*, *.stories.*, *.config.* and anything under __tests__/ __mocks__/ __fixtures__/ test/
# tests/ e2e/ fixtures/ node_modules/ dist/ coverage/ .stryker-tmp*/. Deleted files are never mutated.
#
# Output — KEY=VALUE lines on stdout:
#   config_path=<abs>
#   report_path=<abs>
#   temp_dir=<name>
#   test_runner=<jest|vitest|mocha|command>
#   coverage_analysis=<off|all|perTest>
#   ignore_static=<true|false>
#   scope_mode=<changed-lines|whole-files>
#   diff_base=<ref>@<sha7>|none
#   file_count=<n>
#   mutate_count=<n>          number of `mutate` entries (line ranges + whole files)
#   mutated_lines=<n>
#   changed_lines=<n>|unknown changed lines in mutable production files vs the base
#   run_command=(cd <repo> && npx stryker run <config_path>)
# plus ONE summary line on stderr: files, line ranges, mutated lines vs changed lines.
#
# Exit codes: 0 ok · 2 usage error · 3 no such file, or nothing left to mutate (empty scope)
#             · 4 cannot compute the diff (not a git work tree, no base found)
set -uo pipefail

REPO=""
OUT=""
REPORT=""
RUNNER=""
CONCURRENCY="4"
COVERAGE=""
TIMEOUT_MS="60000"
PRINT_CONFIG=0
DIFF_BASE=""
WHOLE_FILES=0
INCLUDE_STATIC=0
FILES_FLAG=0
FILES=()

die() { echo "$1" >&2; exit "${2:-2}"; }

# Every value-taking flag proves its value exists BEFORE `shift 2`. With a trailing valueless flag,
# `shift 2` on one remaining arg fails WITHOUT consuming it, so `while [ $# -gt 0 ]` re-enters on
# the same token forever — a silent infinite loop instead of the documented exit 2. Reproduced on
# bash 3.2 in review; it spins with no output until something kills it.
need_val() { [ "$1" -ge 2 ] || die "missing value for $2"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --file)        need_val $# "$1"; FILES_FLAG=1; FILES+=("$2"); shift 2 ;;
    --files-from)
      need_val $# "$1"
      [ -f "$2" ] || die "--files-from: no such file: $2"
      FILES_FLAG=1
      # `|| [ -n "$_l" ]` catches a final line with no trailing newline: `read` returns non-zero
      # there and the loop body would never run for it, silently scoping the run to N-1 files.
      # Stryker reports the resulting smaller mutate set as a perfectly successful run.
      while IFS= read -r _l || [ -n "$_l" ]; do
        [ -n "$_l" ] && FILES+=("$_l")
      done < "$2"
      shift 2 ;;
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
[[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || die "--timeout-ms must be an integer"
command -v node >/dev/null 2>&1 || die "node is required (StrykerJS is a node tool) and was not found on PATH"

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
for f in ${FILES[@]+"${FILES[@]}"}; do
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

# ── scope + config emission ─────────────────────────────────────────────────
# One node program computes the scope from git (decision 6), writes the config and prints the
# KEY=VALUE contract. Paths travel as separate argv entries, never through a shell string.
node - "$REPO" "$OUT" "$REPORT" "$TEST_RUNNER" "$COVERAGE" "$CONCURRENCY" "$TIMEOUT_MS" \
  "$INCLUDE_STATIC" "$WHOLE_FILES" "$FILES_FLAG" "$DIFF_BASE" "$PRINT_CONFIG" "$$" \
  ${REL_FILES[@]+"${REL_FILES[@]}"} <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const crypto = require('crypto');

const [repo, outArg, reportArg, runner, coverage, concurrency, timeoutMs, includeStaticArg,
  wholeFilesArg, filesFlagArg, diffBaseArg, printConfigArg, shellPid, ...rawFiles] = process.argv.slice(2);
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

// Decision 6, base. The NEAREST default branch wins: a branch cut from develop in a repo whose
// origin/HEAD is main must be diffed against develop, or every develop commit it inherited since
// main lands in the "changed" set. Remote-tracking refs first, because a local main that carries
// unpushed commits would otherwise be the nearest base and hide exactly those commits.
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

// Stryker matches every `mutate` entry with minimatch, and refuses a line range on any path that
// minimatch considers a glob. `app/[id]/page.tsx` is both a real Next.js file and a glob that
// matches `app/i/page.tsx` — so a whole-file entry is escaped char-class style, and a RANGE on
// such a path is impossible (see the drop below), not merely awkward.
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

// Changed line ranges per file, from `git diff -U0 <base>` against the WORKING TREE (committed +
// staged + unstaged) plus untracked files. Returns Map<relPath, {added:boolean, ranges:[[s,e]]}>.
// The parser counts each hunk's lines from its header instead of pattern-matching them: a removed
// line `-- x` or an added `++ b/evil.ts` prints as `--- x` / `+++ b/evil.ts` inside a hunk, and a
// prefix matcher would take it for the next file's header.
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
      // git appends a TAB to an unquoted ---/+++ path that contains a space (for GNU patch);
      // left on, `x y.ts\t` has no `.ts` extension and the file silently leaves the scope.
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
  // A local Stryker run copies the whole project into `.stryker-tmp-<tag>/` — untracked and often
  // not ignored — so without these excludes its sandbox copies would count as "added" files.
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
const notes = [];

if (wholeFiles && filesGiven) {
  // The explicit opt-out: the old behaviour, git or no git. The diff is still computed when it can
  // be, purely so the cost of the opt-out is printed in lines rather than left to be discovered.
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
    say(`DROPPED ${p}: changed, but its path holds glob characters and Stryker refuses a line range on ` +
      `a glob path. Mutate it whole on purpose with --whole-files --file '${p}', or cover it with the LLM engine.`);
    notes.push(p);
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
  const dropped = [];
  for (const p of givenFiles) {
    const why = whyNotMutable(p);
    if (why) { dropped.push(`${p} (${why})`); continue; }
    const f = changed.get(p);
    if (!f) { dropped.push(`${p} (unchanged vs ${baseLabel})`); continue; }
    addRanges(p, f);
  }
  if (dropped.length) {
    say(`DROPPED ${dropped.length} of ${givenFiles.length} listed files — mutation covers only the lines this branch changed or added ` +
      '(pass --whole-files to mutate them anyway, and say why):');
    for (const d of dropped) say(`  dropped: ${d}`);
  }
  const others = [...mutableChanged.keys()].filter((p) => !givenFiles.includes(p)).length;
  if (others) say(`note: ${others} other changed files are outside the given list and are not mutated`);
} else {
  for (const [p, f] of mutableChanged) addRanges(p, f);
}

if (!entries.length) {
  const why = wholeFiles ? 'no files to mutate'
    : filesGiven ? `none of the listed files has changed lines vs ${baseLabel}`
      : `no changed lines in mutable production files vs ${baseLabel}`;
  fail(3, `${why} — nothing to mutate, no config written (an empty mutate set would score 100% for nothing).`);
}

// A tag that is unique per invocation AND per scope, so two scoped runs on one box never share a
// sandbox. Decision 2: `.stryker-tmp` is the default for every run in the repo.
const tag = `${crypto.createHash('sha1').update(entries.join('\n')).digest('hex').slice(0, 10)}-${shellPid}`;
const out = outArg || path.join(repo, `.stryker-scoped-${tag}.conf.json`);
const report = reportArg || path.join(repo, `.stryker-scoped-${tag}.report.json`);
const tempDir = `.stryker-tmp-${tag}`;

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
  const candidates = ['jest.config.js', 'jest.config.ts', 'jest.config.mjs', 'jest.config.cjs', 'jest.config.json'];
  const found = candidates.find(inRepo);
  cfg.jest = { projectType: 'custom', enableFindRelatedTests: coverage !== 'off' };
  if (found) cfg.jest.configFile = found;
} else if (runner === 'vitest') {
  const candidates = ['vitest.config.ts', 'vitest.config.js', 'vitest.config.mts', 'vite.config.ts', 'vite.config.js'];
  const found = candidates.find(inRepo);
  if (found) cfg.vitest = { configFile: found };
} else if (runner === 'command') {
  // `npm test` with no file filter: correct everywhere, slowest. Override with --runner once the
  // project's real runner plugin is installed.
  cfg.commandRunner = { command: 'npm test' };
}

try {
  fs.writeFileSync(out, JSON.stringify(cfg, null, 2) + '\n');
} catch (e) {
  fail(2, `failed to write config ${out}: ${e.message}`);
}

const rangeCount = entries.filter((e) => /:\d+-\d+$/.test(e)).length;
const pct = changedLines ? ` (${Math.round((100 * mutatedLines) / changedLines)}% of changed)` : '';
say(`scope=${wholeFiles ? 'WHOLE-FILES' : 'changed-lines'} base=${baseLabel} files=${scopedFiles.size} ` +
  `line_ranges=${rangeCount} whole_files=${entries.length - rangeCount} mutated_lines=${mutatedLines} ` +
  `changed_lines=${changedLines === null ? 'unknown' : changedLines}${pct} ignoreStatic=${!includeStatic}` +
  (changed ? ` skipped_non_source=${skippedNonMutable}` : '') +
  (notes.length ? ` dropped_glob_paths=${notes.length}` : ''));

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
  // The CWD is pinned on purpose: `mutate` entries are repo-relative and Stryker resolves them
  // against the RUN's working directory. This script is routinely invoked from elsewhere, and a
  // command run from the wrong directory matches zero files — which Stryker reports as a successful
  // 100% run, the exact silent failure the scope validation above exists to prevent.
  ['run_command', `(cd ${repo} && npx stryker run ${out})`],
];
process.stdout.write(kv.map(([k, v]) => `${k}=${v}\n`).join(''));
if (printConfigArg === '1') process.stdout.write('--- config ---\n' + fs.readFileSync(out, 'utf8'));
NODE
rc=$?
case "$rc" in
  0|2|3|4) exit "$rc" ;;
  *) die "scope/config step failed (node exited $rc)" 2 ;;
esac
