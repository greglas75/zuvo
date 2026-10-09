#!/usr/bin/env bash
# Behaviour tests for the scoper's Vitest wiring (RD-121): scripts/lib/stryker-vitest.cjs and the
# vitest_* contract of scripts/stryker-scoped-config.sh.
#
# Why: a monorepo's root config is often a `test.projects` aggregator, and handing it to Stryker for a
# one-workspace scope runs every project (RD-121). Each case names a way back to that: the wrong config
# picked, an aggregator accepted, the covering tests guessed silently, or a generated config that makes
# Stryker test unmutated originals.
#
# Every case builds a throwaway fixture; nothing touches this checkout.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib/stryker-vitest.cjs"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v node >/dev/null 2>&1 || { printf 'SKIP: node not installed — nothing was tested\n'; exit 0; }
[ -f "$LIB" ] || { bad "missing scripts/lib/stryker-vitest.cjs"; echo "SOME FAILED"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ── A. library tables (pure functions over a fixture tree) ────────────────────────────────────
F="$TMP/lib"
mkdir -p "$F/apps/a/src/deep" "$F/packages/b/src" "$F/tools" "$F/src/__tests__" "$F/src/other" "$F/w"
printf "export default { test: { projects: ['apps/*'] } };\n" > "$F/vitest.config.ts"
printf 'export default {};\n' > "$F/apps/a/vitest.config.ts"
printf 'export default {};\n' > "$F/apps/a/vite.config.ts"
printf 'export default {};\n' > "$F/packages/b/vite.config.mts"
for f in apps/a/src/deep/x.ts packages/b/src/y.ts tools/z.ts src/foo.ts src/foo.test.ts src/foo.spec.tsx \
         src/foobar.test.ts src/__tests__/foo.ts src/__tests__/foo.test.ts src/__tests__/foobar.test.ts \
         src/other/foo.test.ts; do
  : > "$F/$f"
done
# rdesigner's apps/designer config shape: test.include AND a deeper coverage.include.
cat > "$F/designer.config.ts" <<'EOF'
import path from 'path';
export default defineConfig({
  resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
  test: {
    globals: true,
    // include: ['commented/out/**'],
    setupFiles: ['./src/setup.ts'],
    include: [
      'src/**/*.test.ts',
      "src/**/*.spec.tsx", // trailing comment
    ],
    coverage: { include: ['src/**/*.ts'], exclude: ['x'] },
  },
});
EOF
printf "const files = ['a'];\nexport default { test: { include: files } };\n" > "$F/var.config.ts"
printf "export default { test: { globals: true, /* include: ['x'] */ } };\n" > "$F/noinc.config.ts"
printf "import base from './b';\nexport default { ...base, plugins: [] };\n" > "$F/spread.config.ts"
printf "export default { plugins: [] };\n" > "$F/plain.config.ts"
printf "// projects: ['x']\nconst projects = 1;\nexport default { test: { name: 'projects' } };\n" > "$F/w/vitest.config.ts"
mkdir -p "$F/ws2" && printf 'export default {};\n' > "$F/ws2/vitest.config.ts" && printf '[]\n' > "$F/ws2/vitest.workspace.json"
mkdir -p "$F/ws3" && printf "export default { test: { workspace: ['a'] } };\n" > "$F/ws3/vitest.config.ts"
mkdir -p "$F/q1" && printf "export default { test: { 'projects': ['a'] } };\n" > "$F/q1/vitest.config.ts"
mkdir -p "$F/q2" && printf "const projects = ['a'];\nexport default { test: { globals: true, projects } };\n" > "$F/q2/vitest.config.ts"
mkdir -p "$F/q3" && printf "const shared = { test: { globals: true } };\nexport default { test: { projects: ['a'] } };\n" > "$F/q3/vitest.config.ts"
cat > "$F/regex.config.ts" <<'CFG'
const quote = /["']/; const slash = /a\//;
export default { test: { include: ['./src/**/*.test.ts'] } };
CFG
printf "const include = ['x'];\nexport default { test: { include } };\n" > "$F/short.config.ts"
printf "const shared = { test: { include: ['a'] } };\nexport default { test: { include: ['b'] } };\n" > "$F/twice.config.ts"
printf "export default mergeConfig(base, { test: { globals: true } });\n" > "$F/merge.config.ts"
mkdir -p "$F/q4" && printf "export default { \"test\": { \"projects\": ['a'] } };\n" > "$F/q4/vitest.config.ts"
printf "function f() { return /[\"']/; }\nexport default { test: { include: ['src/**/*.test.ts'] } };\n" > "$F/ret.config.ts"
printf "export default mergeConfig(base, { test: { include: ['x'] } });\n" > "$F/mergelist.config.ts"
printf "export default { test: { include: ['x'], ...base.test } };\n" > "$F/spreadinc.config.ts"
# A config ABOVE the repo root is outside Stryker's sandbox and must never be found.
mkdir -p "$TMP/outer/repo/src" && printf 'export default {};\n' > "$TMP/outer/vitest.config.ts"

node - "$LIB" "$F" "$TMP/outer/repo" <<'NODE'
const [lib, F, inner] = process.argv.slice(2);
const v = require(lib);
const fs = require('fs');
const path = require('path');
let failed = false;
const check = (label, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failed = true;
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${label}${ok ? '' : ` — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};
const read = (f) => fs.readFileSync(path.join(F, f), 'utf8');

// findNearestConfig — the RD-121 defect was taking the root config for a workspace file.
check('nearest: workspace config wins over the root aggregator', v.findNearestConfig(F, 'apps/a/src/deep/x.ts'), 'apps/a/vitest.config.ts');
check('nearest: vite.config.mts found when no vitest.* exists', v.findNearestConfig(F, 'packages/b/src/y.ts'), 'packages/b/vite.config.mts');
check('nearest: root config only when nothing nearer', v.findNearestConfig(F, 'tools/z.ts'), 'vitest.config.ts');
check('nearest: never above the repo root (outside the sandbox)', v.findNearestConfig(inner, 'src/q.ts'), null);

// hasProjects — an aggregator runs every project whatever include says.
check('projects: test.projects is an aggregator', v.hasProjects(F, 'vitest.config.ts'), true);
check('projects: the word in a comment / outside test / as a value is not', v.hasProjects(F, 'w/vitest.config.ts'), false);
check('projects: a sibling vitest.workspace.* is an aggregator', v.hasProjects(F, 'ws2/vitest.config.ts'), true);
check('projects: test.workspace is an aggregator', v.hasProjects(F, 'ws3/vitest.config.ts'), true);
check("projects: a quoted 'projects' key is an aggregator", v.hasProjects(F, 'q1/vitest.config.ts'), true);
check('projects: a shorthand { projects } is an aggregator', v.hasProjects(F, 'q2/vitest.config.ts'), true);
check('projects: found in the real test object after an earlier one', v.hasProjects(F, 'q3/vitest.config.ts'), true);
check('projects: a quoted "test" key with "projects" is an aggregator', v.hasProjects(F, 'q4/vitest.config.ts'), true);

// parseTestInclude — the printed include must be test.include, never coverage.include or a comment.
check('include: literal test.include, coverage.include and comments ignored', v.parseTestInclude(read('designer.config.ts')),
  { kind: 'list', globs: ['src/**/*.test.ts', 'src/**/*.spec.tsx'] });
check('include: a non-literal include is unknown, not guessed', v.parseTestInclude(read('var.config.ts')), { kind: 'unknown' });
check('include: test object without include is the vitest default', v.parseTestInclude(read('noinc.config.ts')), { kind: 'default' });
check('include: no test object but a spread base is unknown', v.parseTestInclude(read('spread.config.ts')), { kind: 'unknown' });
check('include: no test object and nothing inherited is the default', v.parseTestInclude(read('plain.config.ts')), { kind: 'default' });
check('include: regex literals with quotes do not derail the scanner; ./ is dropped', v.parseTestInclude(read('regex.config.ts')),
  { kind: 'list', globs: ['src/**/*.test.ts'] });
check('include: a shorthand { include } is unknown, not the default', v.parseTestInclude(read('short.config.ts')), { kind: 'unknown' });
check('include: two test objects are unknown, not the first one', v.parseTestInclude(read('twice.config.ts')), { kind: 'unknown' });
check('include: test merged onto a base (mergeConfig) is unknown', v.parseTestInclude(read('merge.config.ts')), { kind: 'unknown' });
check('workspace: an absolute path terminates', v.workspaceDir(F, '/no/such/x.ts'), '/');
check('include: a regex literal after `return` does not derail the scanner', v.parseTestInclude(read('ret.config.ts')),
  { kind: 'list', globs: ['src/**/*.test.ts'] });
check('include: a literal list merged onto a base is unknown (mergeConfig concatenates)', v.parseTestInclude(read('mergelist.config.ts')), { kind: 'unknown' });
check('include: a spread after the literal list may overwrite it: unknown', v.parseTestInclude(read('spreadinc.config.ts')), { kind: 'unknown' });
// tinyglobby/picomatch (Vitest's matchers) take backslash escapes; a `[c]` class globbed nothing there.
check('escapeGlob: glob characters in a test path are backslash-escaped', v.escapeGlob('app/[id]/b!c/(g)/@x+y.test.ts'),
  'app/\\[id\\]/b\\!c/\\(g\\)/\\@x\\+y.test.ts');
check('resolve: no scoped files is an error, not a crash', v.resolveVitest({ repo: F, files: [], tests: [] }).error, 'no scoped files');
check('resolve: a path that normalizes outside the repo is refused',
  Boolean(v.resolveVitest({ repo: F, files: ['tools/z.ts'], tests: [], override: 'apps/../../x/vitest.config.ts' }).error), true);

// colocatedTests — same stem only, beside the source or in its __tests__.
check('colocated: foo.test/spec beside it and __tests__/foo[.test].*; not foobar, not another dir',
  v.colocatedTests(F, 'src/foo.ts'),
  ['src/__tests__/foo.test.ts', 'src/__tests__/foo.ts', 'src/foo.spec.tsx', 'src/foo.test.ts']);

// renderVitestConfig — evaluated by plain node (the template is plain JS), then RELOCATED: an absolute
// root would make Stryker's sandbox import the unmutated originals and every mutant would survive.
(async () => {
  const R = path.join(path.dirname(F), 'render');
  fs.mkdirSync(path.join(R, 'ws'), { recursive: true });
  const base = "{ resolve: { alias: { '@': 'x' } }, test: { include: ['src/**/*.test.ts'], globals: true } }";
  const bases = { object: `export default ${base};`, promise: `export default Promise.resolve(${base});`,
    function: `export default (env) => ({ ...${base}, mode: env.mode });` };
  for (const [kind, src] of Object.entries(bases)) {
    fs.writeFileSync(path.join(R, 'ws', `${kind}.mjs`), src + '\n');
    fs.writeFileSync(path.join(R, `${kind}.mjs`),
      v.renderVitestConfig({ config: `ws/${kind}.mjs`, root: 'ws', include: ['src/a.test.ts'] }));
    fs.writeFileSync(path.join(R, `${kind}-inherit.mjs`),
      v.renderVitestConfig({ config: `ws/${kind}.mjs`, root: 'ws', include: null }));
  }
  fs.writeFileSync(path.join(R, 'none.mjs'), v.renderVitestConfig({ config: 'none', root: '.', include: ['a.test.ts'] }));
  const R2 = `${R}-moved`;
  fs.cpSync(R, R2, { recursive: true });
  const env = { mode: 'test', command: 'serve' };
  const load = async (dir, f) => (await import(path.join(dir, f))).default(env);
  for (const kind of Object.keys(bases)) {
    const c = await load(R2, `${kind}.mjs`);
    check(`render (${kind} base): include replaced, not concatenated`, c.test.include, ['src/a.test.ts']);
    check(`render (${kind} base): other base keys kept`, [c.resolve.alias['@'], c.test.globals], ['x', true]);
    check(`render (${kind} base): root, test.root, test.dir follow the relocated copy`,
      [c.root, c.test.root, c.test.dir], Array(3).fill(path.join(R2, 'ws')));
    const i = await load(R2, `${kind}-inherit.mjs`);
    check(`render (${kind} base): workspace-include mode keeps the workspace include`, i.test.include, ['src/**/*.test.ts']);
  }
  const n = await load(R2, 'none.mjs');
  check('render (no config): base-less config rooted at the repo', [n.root, n.test.include], [R2, ['a.test.ts']]);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.log(`FAIL: render threw ${e.stack}`); process.exit(1); });
NODE
[ $? -eq 0 ] || fail=1

# ── B. scoper inputs: explicit covering tests and a config override ───────────────────────────
STRYKER="$ROOT/scripts/stryker-scoped-config.sh"
M="$TMP/mono"
mkdir -p "$M/apps/a/src/__tests__" "$M/apps/c/src" "$M/packages/b/src"
printf '{"name":"m","private":true,"devDependencies":{"vitest":"^4.0.0"}}\n' > "$M/package.json"
printf "export default { test: { projects: ['apps/*', 'packages/*'] } };\n" > "$M/vitest.config.ts"
printf "export default { test: { include: ['src/**/*.test.ts'], coverage: { include: ['src/**'] } } };\n" > "$M/apps/a/vitest.config.ts"
printf '{"name":"a"}\n' > "$M/apps/a/package.json"
printf '{"name":"c"}\n' > "$M/apps/c/package.json"
printf "export default {};\n" > "$M/packages/b/vite.config.mts"
printf 'export const x = 1;\n' > "$M/apps/a/src/x.ts"
printf 'export const x = 1;\n' > "$M/apps/a/src/x.test.ts"
printf 'export const h = 1;\n' > "$M/apps/a/src/h.ts"
printf 'export const h = 1;\n' > "$M/apps/a/src/__tests__/h.ts"
printf 'export const n = 1;\n' > "$M/apps/a/src/nocover.ts"
printf 'export const y = 1;\n' > "$M/packages/b/src/y.ts"
printf 'export const z = 1;\n' > "$M/apps/c/src/z.ts"
printf 'export const o = 1;\n' > "$TMP/outside.test.ts"   # exists, but outside the repo $M
# Every refused run must leave nothing behind: a half-written config is a run waiting to happen.
written() { find "$M" -maxdepth 1 -name '.stryker-scoped-*' | wc -l | tr -d ' '; }
scope() { (cd "$M" && bash "$STRYKER" --repo "$M" --whole-files "$@" 2>"$TMP/scope.err"); }

input_row() {  # $1 label, $2 expected rc, $3 stderr fragment that names the reason, rest = scoper args
  local label="$1" want="$2" why="$3" before; shift 3
  before="$(written)"
  scope "$@" >/dev/null; local rc=$?
  if [ "$rc" = "$want" ] && [ "$(written)" = "$before" ] && grep -qF -- "$why" "$TMP/scope.err"; then
    pass "input: $label → $want ($why), nothing written"
  else bad "input: $label gave rc=$rc (want $want), files written: $(( $(written) - before )) — $(head -c 300 "$TMP/scope.err")"; fi
}
input_row "--vitest-config that does not exist" 1 "no such file: apps/a/nope.config.ts" --runner vitest --file apps/a/src/x.ts --vitest-config apps/a/nope.config.ts
input_row "--test-file with the jest runner (silently ignored)" 2 "vitest runner only" --runner jest --file apps/a/src/x.ts --test-file apps/a/src/gone.test.ts
input_row "--vitest-config with the jest runner (silently ignored)" 2 "vitest runner only" --runner jest --file apps/a/src/x.ts --vitest-config apps/a/nope.config.ts
input_row "--vitest-config outside the repo" 3 "outside --repo" --runner vitest --file apps/a/src/x.ts --vitest-config "$TMP/outside.test.ts"
input_row "--test-file that does not exist" 3 "no such file" --runner vitest --file apps/a/src/x.ts --test-file apps/a/src/gone.test.ts
input_row "--test-file escaping the repo" 3 "outside --repo" --runner vitest --file apps/a/src/x.ts --test-file "$TMP/outside.test.ts"
ln -s "$TMP/outside.test.ts" "$M/apps/a/src/link.test.ts"
input_row "--test-file that is a symlink to a file outside the repo" 3 "through a symlink" --runner vitest --file apps/a/src/x.ts --test-file apps/a/src/link.test.ts
input_row "--test-file whose name holds a newline" 3 "holds a newline" --runner vitest --file apps/a/src/x.ts --test-file "$(printf 'a\nb')"
printf 'apps/a/src/x.test.ts\n../outside.test.ts\n' > "$TMP/escape-tests.txt"
input_row "--tests-from escaping the repo" 3 "outside --repo" --runner vitest --file apps/a/src/x.ts --tests-from "$TMP/escape-tests.txt"
# The last line has no newline and names a missing file: exit 3 proves it was read, not dropped.
printf 'apps/a/src/x.test.ts\napps/a/src/gone.test.ts' > "$TMP/no-eol-tests.txt"
input_row "--tests-from keeps a final line without a newline" 3 "gone.test.ts" --runner vitest --file apps/a/src/x.ts --tests-from "$TMP/no-eol-tests.txt"
: > "$TMP/empty-tests.txt"
input_row "an empty --tests-from (would silently fall back)" 2 "list is empty" --runner vitest --file apps/a/src/x.ts --tests-from "$TMP/empty-tests.txt"
# The accepted half: valid flags produce a config (a refuse-everything scoper would pass the rows above).
printf 'apps/a/src/x.test.ts\r\n' > "$TMP/crlf-tests.txt"
for args in "--test-file apps/a/src/x.test.ts" "--tests-from $TMP/crlf-tests.txt" "--vitest-config apps/a/vitest.config.ts"; do
  # shellcheck disable=SC2086  # the row is a word list on purpose
  out="$(scope --runner vitest --file apps/a/src/x.ts $args)"; rc=$?
  cfg="$(sed -n 's/^config_path=//p' <<<"$out")"
  [ "$rc" = 0 ] && [ -f "$cfg" ] && pass "input: [$args] accepted, config written" || bad "input: [$args] gave rc=$rc — $(head -c 300 "$TMP/scope.err")"
done

if [ "$fail" = 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
