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
# STRYKER_SCOPER points the whole file at ANOTHER copy (a pre-fix scoper, to see these tests fail):
# the lib and the watchdog ship beside it, exactly as the installer lays them out.
STRYKER="${STRYKER_SCOPER:-$ROOT/scripts/stryker-scoped-config.sh}"
STRYKER="$(cd "$(dirname "$STRYKER")" && pwd)/$(basename "$STRYKER")"   # absolute: the fixtures cd elsewhere
LIB="$(dirname "$STRYKER")/lib/stryker-vitest.cjs"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v node >/dev/null 2>&1 || { printf 'SKIP: node not installed — nothing was tested\n'; exit 0; }
[ -f "$LIB" ] || { bad "missing scripts/lib/stryker-vitest.cjs"; echo "SOME FAILED"; exit 1; }

# Physical path: macOS mktemp gives /var/..., which node and git report as /private/var/....
TMP="$(cd "$(mktemp -d)" && pwd -P)"
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
# An INLINE project list (objects defined in this file) is narrowable; anything pointing elsewhere is not.
mkdir -p "$F/inline-projects" && cat > "$F/inline-projects/vitest.config.ts" <<'EOF'
import { defineConfig, defineProject } from 'vitest/config';
export default defineConfig({
  test: {
    root: 'src',
    environment: 'happy-dom',
    projects: [
      { extends: true, test: { name: 'dom', include: ['**/*.dom.test.ts'] } },
      defineProject({ extends: true, test: { name: 'node', environment: 'node', include: ['**/*.node.test.ts'] } }),
    ],
  },
});
EOF
mkdir -p "$F/q5" && printf "export default { test: { projects: [...base] } };\n" > "$F/q5/vitest.config.ts"
mkdir -p "$F/later-projects" && printf "export default { test: { projects: [{ extends: true, test: { name: 'a' } }] } };\nexport const later = { test: { projects: ['apps/*'] } };\n" \
  > "$F/later-projects/vitest.config.ts"
# Vitest and the vitest-runner, installed: the separator each builds a full test name with is readable.
mk_pkg() {  # $1 = node_modules dir, $2 = package name, $3 = version, $4 = main
  mkdir -p "$1/$2"
  printf '{"name":"%s","version":"%s","main":"%s"}\n' "$2" "$3" "$4" > "$1/$2/package.json"
}
SEP="$TMP/sep"
mk_pkg "$SEP/node_modules" vitest 5.0.5 dist/index.js
mkdir -p "$SEP/node_modules/vitest/dist" && : > "$SEP/node_modules/vitest/dist/index.js"
printf 'export function createTaskName(names, separator = " > ") { return names.join(separator); }\n' > "$SEP/node_modules/vitest/dist/task-utils.js"
mk_pkg "$SEP/node_modules" @stryker-mutator/vitest-runner 10.0.0 dist/index.js
mkdir -p "$SEP/node_modules/@stryker-mutator/vitest-runner/dist/src"
: > "$SEP/node_modules/@stryker-mutator/vitest-runner/dist/index.js"
printf 'export function collectTestName({ name, suite }) {\n  const nameParts = [name];\n  return nameParts.join(" ").trim();\n}\n' \
  > "$SEP/node_modules/@stryker-mutator/vitest-runner/dist/src/test-helpers.js"
cp -R "$SEP" "$TMP/sep-ok"   # the same packages, with the separator the runner builds
printf 'export function collectTestName({ name, suite }) {\n  const nameParts = [name];\n  return nameParts.join(" > ").trim();\n}\n' \
  > "$TMP/sep-ok/node_modules/@stryker-mutator/vitest-runner/dist/src/test-helpers.js"
printf "function f() { return /[\"']/; }\nexport default { test: { include: ['src/**/*.test.ts'] } };\n" > "$F/ret.config.ts"
printf "export default mergeConfig(base, { test: { include: ['x'] } });\n" > "$F/mergelist.config.ts"
printf "export default { test: { include: ['x'], ...base.test } };\n" > "$F/spreadinc.config.ts"
printf "const shared = { projects: ['a'] };\nexport default { test: shared };\n" > "$F/opaque.config.ts"
# A config ABOVE the repo root is outside Stryker's sandbox and must never be found.
mkdir -p "$TMP/outer/repo/src" && printf 'export default {};\n' > "$TMP/outer/vitest.config.ts"

node - "$LIB" "$F" "$TMP/outer/repo" "$SEP" "$TMP/sep-ok" <<'NODE'
const [lib, F, inner, SEP, SEPOK] = process.argv.slice(2);
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

// projectsForm — an inline list of project OBJECTS is defined in this file and can be narrowed; a
// list of globs/strings names OTHER configs (refused), and so does anything unreadable.
check('projects form: glob strings point at other configs (opaque)', v.projectsForm(F, 'vitest.config.ts').kind, 'opaque');
check('projects form: inline project objects are narrowable (inline, with the count)',
  v.projectsForm(F, 'inline-projects/vitest.config.ts'), { kind: 'inline', key: 'projects', count: 2 });
check('projects form: a shorthand { projects } cannot be read (opaque)', v.projectsForm(F, 'q2/vitest.config.ts').kind, 'opaque');
check('projects form: a spread inside the array may add outside projects (opaque)', v.projectsForm(F, 'q5/vitest.config.ts').kind, 'opaque');
check('projects form: a config that declares none', v.projectsForm(F, 'plain.config.ts'), { kind: 'none' });
// The FIRST projects key can look safe while a later one names other configs (both would run).
check('projects form: a later projects key naming project files makes the config opaque',
  v.projectsForm(F, 'later-projects/vitest.config.ts').kind, 'opaque');

// vitestRunnerVerdict — the runner's per-test filter joins suite names with its own separator; the
// verdict must be MEASURED from the installed packages, never guessed.
check('runner verdict: a measured separator mismatch (vitest " > " vs runner " ") is refused',
  [v.vitestRunnerVerdict(SEP).ok, v.vitestRunnerVerdict(SEP).unknown], [false, false]);
check('runner verdict: the mismatch reason names both separators',
  /" > "/.test(v.vitestRunnerVerdict(SEP).reason) && /" "/.test(v.vitestRunnerVerdict(SEP).reason), true);
check('runner verdict: equal separators are accepted',
  [v.vitestRunnerVerdict(SEPOK).ok, v.vitestRunnerVerdict(SEPOK).reason.includes('" > "')], [true, true]);
check('runner verdict: packages that are not installed are UNKNOWN, not a refusal',
  [v.vitestRunnerVerdict(F).ok, v.vitestRunnerVerdict(F).unknown], [false, true]);

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
check('include: `test: shared` (options in a variable) is unknown, not the default', v.parseTestInclude(read('opaque.config.ts')), { kind: 'unknown' });
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
  const base = "{ resolve: { alias: { '@': 'x' } }, test: { include: ['src/**/*.test.ts'], exclude: ['src/a.test.ts'], projects: ['other/*'], globals: true } }";
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
  // A base that roots its tests (apps/runner: test.root = path.resolve(configDir,'src') with
  // setupFiles './test-setup.ts', relative to that root): the scoped config must KEEP the root and
  // state the selected test relative to it. Overriding it pointed setupFiles at apps/runner/ and the
  // initial run died on "Cannot find module …/apps/runner/test-setup.ts" (farm 1792488745-1939124-20968).
  const rooted = (rootExpr) => `export default { test: { root: ${rootExpr}, setupFiles: ['./test-setup.ts'], include: ['**/*.test.ts'] } };\n`;
  fs.mkdirSync(path.join(R, 'ws', 'src'), { recursive: true });
  for (const f of ['test-setup.ts', 'a.test.ts']) fs.writeFileSync(path.join(R, 'ws', 'src', f), '');
  fs.writeFileSync(path.join(R, 'ws', 'rooted.mjs'), rooted("'src'"));
  fs.writeFileSync(path.join(R, 'ws', 'rooted-abs.mjs'), "import path from 'node:path';\n" + rooted('path.resolve(import.meta.dirname, "src")'));
  for (const k of ['rooted', 'rooted-abs']) {
    fs.writeFileSync(path.join(R, `${k}-scoped.mjs`),
      v.renderVitestConfig({ config: `ws/${k}.mjs`, root: 'ws', include: ['src/a.test.ts'], tests: ['src/a.test.ts'] }));
  }
  fs.writeFileSync(path.join(R, 'rooted-outside.mjs'),
    v.renderVitestConfig({ config: 'ws/rooted.mjs', root: 'ws', include: ['a.test.ts'], tests: ['a.test.ts'] }));
  const R2 = `${R}-moved`;
  fs.cpSync(R, R2, { recursive: true });
  const env = { mode: 'test', command: 'serve' };
  const load = async (dir, f) => (await import(path.join(dir, f))).default(env);
  for (const kind of Object.keys(bases)) {
    const c = await load(R2, `${kind}.mjs`);
    check(`render (${kind} base): include replaced, not concatenated`, c.test.include, ['src/a.test.ts']);
    check(`render (${kind} base): a base exclude cannot drop the selected covering test`, c.test.exclude, []);
    check(`render (${kind} base): projects a base brings in at runtime are dropped when narrowing`, c.test.projects, undefined);
    check(`render (${kind} base): other base keys kept`, [c.resolve.alias['@'], c.test.globals], ['x', true]);
    check(`render (${kind} base): root, test.root, test.dir follow the relocated copy`,
      [c.root, c.test.root, c.test.dir], Array(3).fill(path.join(R2, 'ws')));
    const i = await load(R2, `${kind}-inherit.mjs`);
    check(`render (${kind} base): workspace-include mode keeps the workspace include`, i.test.include, ['src/**/*.test.ts']);
    // Not narrowing must not resurrect what narrowing drops: a runtime `projects` fans out to every
    // project and the scoped run silently executes the whole workspace.
    check(`render (${kind} base): workspace-include mode still drops the base's runtime projects`,
      [i.test.projects, i.test.workspace], [undefined, undefined]);
  }
  for (const k of ['rooted', 'rooted-abs']) {
    const c = await load(R2, `${k}-scoped.mjs`);
    const baseRoot = path.join(R2, 'ws', 'src');
    check(`render (${k} base): the base's own test.root is kept, the test is stated relative to it`,
      [c.test.root, c.test.include], [baseRoot, ['a.test.ts']]);
    check(`render (${k} base): setupFiles resolves against the kept root (the file it names exists)`,
      [c.test.setupFiles, fs.existsSync(path.resolve(c.test.root, c.test.setupFiles[0]))], [['./test-setup.ts'], true]);
  }
  // A covering test the base root cannot reach: an absolute include would collect the UNMUTATED
  // original inside Stryker's sandbox (every mutant survives), so the config must refuse to load.
  let refused = '';
  try { await load(R2, 'rooted-outside.mjs'); } catch (e) { refused = String(e && e.message); }
  check('render (rooted base): a test outside the base root refuses the config, never an absolute include',
    /outside the base config test\.root/.test(refused), true);
  const n = await load(R2, 'none.mjs');
  check('render (no config): base-less config rooted at the repo', [n.root, n.test.include], [R2, ['a.test.ts']]);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.log(`FAIL: render threw ${e.stack}`); process.exit(1); });
NODE
[ $? -eq 0 ] || fail=1

# ── B. scoper inputs: explicit covering tests and a config override ───────────────────────────
M="$TMP/mono"
mkdir -p "$M/apps/a/src/__tests__" "$M/apps/c/src" "$M/packages/b/src"
printf '{"name":"m","private":true,"devDependencies":{"vitest":"^4.0.0"}}\n' > "$M/package.json"
printf "export default { test: { projects: ['apps/*', 'packages/*'] } };\n" > "$M/vitest.config.ts"
printf "export default { test: { include: ['src/**/*.test.ts', 'src/**/*.spec.ts', '!src/**/*.e2e.spec.ts'], exclude: ['src/**/*.slow.spec.ts'], coverage: { include: ['src/**'] } } };\n" > "$M/apps/a/vitest.config.ts"
printf '{"name":"a"}\n' > "$M/apps/a/package.json"
printf '{"name":"c"}\n' > "$M/apps/c/package.json"
printf "export default {};\n" > "$M/packages/b/vite.config.mts"
printf 'export const x = 1;\n' > "$M/apps/a/src/x.ts"
printf 'export const x = 1;\n' > "$M/apps/a/src/x.test.ts"
printf 'export const h = 1;\n' > "$M/apps/a/src/h.ts"
printf 'export const h = 1;\n' > "$M/apps/a/src/__tests__/h.ts"
printf 'export const n = 1;\n' > "$M/apps/a/src/nocover.ts"
printf 'export const e = 1;\n' > "$M/apps/a/src/e.ts"
: > "$M/apps/a/src/e.e2e.spec.ts"; : > "$M/apps/a/src/e.slow.spec.ts"   # Playwright / excluded, not Vitest
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
ln -s link.test.ts "$M/apps/a/src/chain.test.ts"   # chain.test.ts -> link.test.ts -> outside the repo
input_row "--test-file whose symlink CHAIN leaves the repo" 3 "through a symlink" --runner vitest --file apps/a/src/x.ts --test-file apps/a/src/chain.test.ts
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

# ── C. which config, which tests — and they are printed BEFORE the run is admitted ─────────────
kvs() { sed -n "s/^$2=//p" <<<"$1"; }   # every value of key $2, one per line
kv1() { kvs "$1" "$2" | head -1; }
OUT=""; RC=0
run_scope() { OUT="$(scope --runner vitest "$@")"; RC=$?; }

run_scope --file apps/a/src/x.ts
if [ "$RC" = 0 ] && [ "$(kv1 "$OUT" vitest_config)" = apps/a/vitest.config.ts ] && [ "$(kv1 "$OUT" vitest_root)" = apps/a ]; then
  pass "nearest: the workspace config, not the root aggregator (the RD-121 defect)"
else
  bad "nearest: rc=$RC vitest_config=$(kv1 "$OUT" vitest_config) vitest_root=$(kv1 "$OUT" vitest_root) — $(head -c 300 "$TMP/scope.err")"
fi
keys_line="$(grep -nE '^(vitest_[a-z_]+|run_command)=' <<<"$OUT" | tail -1)"
case "$keys_line" in *:run_command=*) pass "order: every vitest_* key precedes run_command" ;; *) bad "order: a vitest_* key after run_command ($keys_line)" ;; esac
summary="$(grep 'scope=' "$TMP/scope.err" | head -1)"
case "$summary" in *vitest_config=apps/a/vitest.config.ts*vitest_root=apps/a*vitest_include_source=colocated*vitest_include_count=1*vitest_include=src/x.test.ts*) pass "stderr summary mirrors the vitest keys" ;;
  *) bad "stderr summary lacks the vitest keys: $summary" ;; esac
[ "$(kv1 "$OUT" vitest_include_source)" = colocated ] && [ "$(kv1 "$OUT" vitest_include_count)" = 1 ] \
  && [ "$(kvs "$OUT" vitest_include)" = src/x.test.ts ] \
  && pass "colocated: exactly the co-located test, workspace-relative" \
  || bad "colocated: source=$(kv1 "$OUT" vitest_include_source) count=$(kv1 "$OUT" vitest_include_count) include=[$(kvs "$OUT" vitest_include | tr '\n' ' ')]"

run_scope --file apps/a/src/x.ts --test-file apps/a/src/__tests__/h.ts
[ "$RC" = 0 ] && [ "$(kv1 "$OUT" vitest_include_source)" = explicit ] && [ "$(kvs "$OUT" vitest_include)" = src/__tests__/h.ts ] \
  && pass "explicit: --test-file wins over the co-located test" \
  || bad "explicit: rc=$RC source=$(kv1 "$OUT" vitest_include_source) include=[$(kvs "$OUT" vitest_include | tr '\n' ' ')]"
before="$(written)"; run_scope --file apps/a/src/x.ts --test-file packages/b/src/y.ts
[ "$RC" = 2 ] && [ "$(written)" = "$before" ] && pass "explicit: a test outside vitest_root → 2 (Vitest could never collect it)" \
  || bad "explicit outside root: rc=$RC"

# Co-located files the workspace's own config never collects — a negated include (`!…e2e.spec.ts`) or
# test.exclude — are not covering tests; e.ts has only those, so it falls back.
run_scope --file apps/a/src/e.ts
[ "$(kv1 "$OUT" vitest_include_source)" = workspace-include ] \
  && pass "co-located file excluded by the config (negated include / test.exclude) is not a covering test" \
  || bad "excluded co-located test was selected: source=$(kv1 "$OUT" vitest_include_source) include=[$(kvs "$OUT" vitest_include | tr '\n' ' ')]"

# A helper in __tests__ that the include never collects is not a covering test: Vitest would fail the
# initial run with "No test suite found". h.ts has only such a helper, so the scope falls back.
run_scope --file apps/a/src/h.ts
[ "$(kv1 "$OUT" vitest_include_source)" = workspace-include ] && ! kvs "$OUT" vitest_include | grep -q '__tests__/h.ts' \
  && pass "helper: __tests__/h.ts outside the include is not made a covering test" \
  || bad "helper: source=$(kv1 "$OUT" vitest_include_source) include=[$(kvs "$OUT" vitest_include | tr '\n' ' ')]"

run_scope --file apps/a/src/x.ts --file apps/a/src/nocover.ts
if [ "$RC" = 0 ] && [ "$(kv1 "$OUT" vitest_include_source)" = workspace-include ] \
   && [ "$(kvs "$OUT" vitest_include | tr '\n' ' ')" = 'src/**/*.test.ts src/**/*.spec.ts !src/**/*.e2e.spec.ts ' ] && grep -q 'WARNING covering_tests=workspace-include' "$TMP/scope.err" \
   && grep -q 'apps/a/src/nocover.ts' "$TMP/scope.err" && [ "$(kvs "$OUT" vitest_missing_tests)" = apps/a/src/nocover.ts ]; then
  pass "workspace-include: a file without a co-located test → the workspace's test.include (not coverage.include), loudly"
else
  bad "workspace-include: rc=$RC source=$(kv1 "$OUT" vitest_include_source) include=[$(kvs "$OUT" vitest_include | tr '\n' ' ')]"
fi

mkdir -p "$M/apps/v/src" && printf '{"name":"v"}\n' > "$M/apps/v/package.json"
printf "const inc = ['src/**/*.test.ts'];\nexport default { test: { include: inc } };\n" > "$M/apps/v/vitest.config.ts"
printf 'export const v = 1;\n' > "$M/apps/v/src/v.ts"
run_scope --file apps/v/src/v.ts
[ "$(kv1 "$OUT" vitest_include_count)" = unknown ] && [ "$(kvs "$OUT" vitest_include)" = '<inherited from apps/v/vitest.config.ts>' ] \
  && pass "unknown include: count=unknown and one inherited-from line, never a guessed glob" \
  || bad "unknown include: count=$(kv1 "$OUT" vitest_include_count) include=[$(kvs "$OUT" vitest_include | tr '\n' ' ')]"

before="$(written)"; run_scope --file apps/a/src/x.ts --file packages/b/src/y.ts
if [ "$RC" = 5 ] && [ "$(written)" = "$before" ] && [ "$(kvs "$OUT" vitest_group | wc -l | tr -d ' ')" = 2 ] \
   && kvs "$OUT" vitest_group | grep -qx 'apps/a/vitest.config.ts -> apps/a/src/x.ts' \
   && kvs "$OUT" vitest_group | grep -qx 'packages/b/vite.config.mts -> packages/b/src/y.ts' && [ -z "$(kv1 "$OUT" config_path)" ]; then
  pass "two workspaces: exit 5, one vitest_group per config, nothing written, no config_path"
else
  bad "two workspaces: rc=$RC groups=[$(kvs "$OUT" vitest_group | tr '\n' ';')] config_path=$(kv1 "$OUT" config_path)"
fi
before="$(written)"; run_scope --file apps/c/src/z.ts
[ "$RC" = 5 ] && [ "$(written)" = "$before" ] && [ "$(kv1 "$OUT" vitest_aggregator)" = vitest.config.ts ] \
  && [ "$(kvs "$OUT" vitest_group)" = 'apps/c -> apps/c/src/z.ts' ] \
  && pass "aggregator: nearest config is the root test.projects → 5 with the workspace named" \
  || bad "aggregator (projects): rc=$RC groups=[$(kvs "$OUT" vitest_group | tr '\n' ';')]"
W="$TMP/wsonly"; mkdir -p "$W/src"
printf '{"name":"w","devDependencies":{"vitest":"^4"}}\n' > "$W/package.json"; printf 'export default {};\n' > "$W/vitest.config.ts"
printf '[]\n' > "$W/vitest.workspace.ts"; printf 'export const w = 1;\n' > "$W/src/w.ts"
(cd "$W" && bash "$STRYKER" --repo "$W" --whole-files --runner vitest --file src/w.ts >/dev/null 2>&1); rc=$?
[ "$rc" = 5 ] && [ -z "$(find "$W" -maxdepth 1 -name '.stryker-scoped-*')" ] && pass "aggregator: a root with vitest.workspace.ts → 5" || bad "aggregator (workspace file): rc=$rc"
before="$(written)"; run_scope --file apps/a/src/x.ts --vitest-config vitest.config.ts
[ "$RC" = 2 ] && [ "$(written)" = "$before" ] && pass "override: an aggregator given as --vitest-config → 2 (deviation 7)" \
  || bad "override aggregator: rc=$RC"
run_scope --file apps/c/src/z.ts --vitest-config apps/a/vitest.config.ts --test-file apps/a/src/x.test.ts
[ "$RC" = 0 ] && [ "$(kv1 "$OUT" vitest_config)" = apps/a/vitest.config.ts ] \
  && pass "override: --vitest-config wins over the nearest config" || bad "override: rc=$RC vitest_config=$(kv1 "$OUT" vitest_config)"

N="$TMP/noconf"; mkdir -p "$N/src"
printf '{"name":"n","devDependencies":{"vitest":"^4"}}\n' > "$N/package.json"; printf 'export const q = 1;\n' > "$N/src/q.ts"
out_n="$(cd "$N" && bash "$STRYKER" --repo "$N" --whole-files --runner vitest --file src/q.ts 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(kv1 "$out_n" vitest_config)" = none ] && [ "$(kv1 "$out_n" vitest_root)" = . ] \
  && [ "$(kvs "$out_n" vitest_include)" = '**/*.{test,spec}.?(c|m)[jt]s?(x)' ] \
  && pass "no config at all: vitest_config=none, root ., Vitest's default include" \
  || bad "no config: rc=$rc config=$(kv1 "$out_n" vitest_config) include=[$(kvs "$out_n" vitest_include)]"

ALONE="$TMP/alone"; mkdir -p "$ALONE" && cp "$STRYKER" "$(dirname "$STRYKER")/stryker-run-watchdog.sh" "$ALONE/"
(cd "$M" && bash "$ALONE/stryker-scoped-config.sh" --repo "$M" --whole-files --runner vitest --file apps/a/src/x.ts >/dev/null 2>"$TMP/alone.err"); rc=$?
[ "$rc" = 2 ] && grep -q 'lib/stryker-vitest.cjs' "$TMP/alone.err" \
  && pass "scoper without its lib/: exit 2 naming the lib, never the old repo-root guess" \
  || bad "scoper without lib: rc=$rc err=$(head -c 200 "$TMP/alone.err")"

# ── D. the narrowed config Stryker actually runs ──────────────────────────────────────────────
configfile_of() {  # the vitest.configFile of the Stryker JSON printed as config_path
  node -e 'const c=require(process.argv[1]); process.stdout.write((c.vitest && c.vitest.configFile) || "")' "$(kv1 "$1" config_path)"
}
run_scope --file apps/a/src/x.ts
gen="$(configfile_of "$OUT")"
case "$gen" in
  .stryker-scoped-*.vitest.config.mts)
    printed_inc="const include = [\"$(kvs "$OUT" vitest_include)\"];"
    if [ -f "$M/$gen" ] && grep -qxF "$printed_inc" "$M/$gen" && grep -qF "import base from \"./apps/a/vitest.config.ts\";" "$M/$gen"; then
      pass "generated config: Stryker runs the repo-relative narrowed config, whose include is exactly the printed one"
    else bad "generated config $gen: missing, or include/import differ from what was printed"; fi ;;
  *) bad "vitest.configFile=$gen — Stryker would load an un-narrowed config (the RD-121 defect)" ;;
esac
# The generated config LOADED (not grepped) against an app that roots its tests at src/ and names
# setupFiles against that root — apps/runner's shape. The scoper's own root is the config's directory,
# so the covering test must be stated relative to IT; repo-relative paths resolved to
# apps/runner/apps/runner/src/... and the config refused to load (farm 1792490064-3105511-31783).
mkdir -p "$M/apps/d/src"
printf '{"name":"d"}\n' > "$M/apps/d/package.json"
printf "import path from 'node:path';\nexport default { test: { root: path.resolve(import.meta.dirname, 'src'), setupFiles: ['./s.mjs'] } };\n" > "$M/apps/d/vitest.config.mjs"
printf 'export const s = 1;\n' > "$M/apps/d/src/s.mjs"
printf 'export const x = 1;\n' > "$M/apps/d/src/x.ts"
printf 'export const x = 1;\n' > "$M/apps/d/src/x.test.ts"
run_scope --file apps/d/src/x.ts
gen="$(configfile_of "$OUT")"; inc="$(kvs "$OUT" vitest_include | head -1)"
cp "$M/$gen" "$M/check.mjs"
url="$(node -e 'process.stdout.write(require("url").pathToFileURL(process.argv[1]).href)' "$M/check.mjs")"
want="$(node -e 'process.stdout.write(JSON.stringify([process.argv[1] + "/apps/d/src", [process.argv[2].split("/").pop()], ["./s.mjs"]]))' "$M" "$inc")"
got="$(node --input-type=module -e 'const c = await (await import(process.argv[1])).default({}); process.stdout.write(JSON.stringify([c.test.root, c.test.include, c.test.setupFiles]))' "$url" 2>&1)"
rm -f "$M/check.mjs"
[ "$RC" = 0 ] && [ "$got" = "$want" ] \
  && pass "generated config: loaded, it keeps the app's own test.root and states the test relative to it" \
  || bad "generated config (apps/d): rc=$RC got=$got want=$want"
first="$gen"
run_scope --file apps/a/src/x.ts
second="$(configfile_of "$OUT")"
[ "$RC" = 0 ] && [ -n "$second" ] && [ "$second" != "$first" ] && pass "generated config: two runs never share (and overwrite) one config" \
  || bad "generated config: two runs share $first"

run_scope --file apps/a/src/x.ts --file apps/a/src/nocover.ts
gen="$(configfile_of "$OUT")"
grep -qxF 'const include = null;' "$M/$gen" 2>/dev/null \
  && pass "generated config: workspace-include mode leaves the workspace include untouched" \
  || bad "generated config ($gen): workspace-include mode overrides the include"

if [ "$(id -u)" = 0 ]; then
  printf 'SKIP: rollback of a pre-existing --out (root ignores mode 444) — not exercised on this machine\n'
else
  printf 'keep me\n' > "$M/existing.json"; chmod 444 "$M/existing.json"   # exists, and cannot be overwritten
  before="$(written)"; scope --runner vitest --file apps/a/src/x.ts --out "$M/existing.json" >/dev/null; rc=$?
  [ "$rc" = 2 ] && [ "$(written)" = "$before" ] && [ "$(cat "$M/existing.json")" = 'keep me' ] \
    && pass "write failure: a pre-existing file is never deleted by the rollback" || bad "rollback touched a pre-existing file or left files (rc=$rc)"
fi
before="$(written)"; scope --runner vitest --file apps/a/src/x.ts --out "$TMP/no/such/dir/x.json" >/dev/null; rc=$?
[ "$rc" = 2 ] && [ "$(written)" = "$before" ] \
  && pass "write failure: exit 2 and the generated Vitest config is removed again (no half-written run)" \
  || bad "write failure: rc=$rc, $(( $(written) - before )) file(s) left behind"

out_n="$(cd "$N" && bash "$STRYKER" --repo "$N" --whole-files --runner vitest --file src/q.ts 2>/dev/null)"
gen="$(configfile_of "$out_n")"
if [ -f "$N/$gen" ] && grep -qxF 'const base = {};' "$N/$gen" && ! grep -q '^import base' "$N/$gen"; then
  pass "generated config: with no Vitest config at all it imports nothing"
else bad "generated config without a base ($gen) is missing or imports one"; fi

# ── E. the run goes through the no-progress watchdog, with an explicit initial-run limit ──────
WATCHDOG="$ROOT/scripts/stryker-run-watchdog.sh"
cfg_val() { node -e 'const c=require(process.argv[1]); process.stdout.write(JSON.stringify(c[process.argv[2]]))' "$(kv1 "$1" config_path)" "$2"; }
run_scope --file apps/a/src/x.ts
cmd="$(kv1 "$OUT" run_command)"
wd="$(sed -n 's/.*bash \.\/\(\.stryker-scoped-[^ ]*\.watchdog\.sh\) .*/\1/p' <<<"$cmd")"
case "$cmd" in
  "(cd $M && bash ./.stryker-scoped-"*".watchdog.sh "*"--idle-timeout 600 -- npx stryker run "*")")
    if [ -n "$wd" ] && cmp -s "$M/$wd" "$WATCHDOG"; then
      pass "run_command: the repo-local copy of the watchdog (rt syncs the repo, not the plugin) wraps npx stryker"
    else bad "run_command names $wd, which is missing or not a copy of scripts/stryker-run-watchdog.sh"; fi ;;
  *) bad "run_command does not go through the watchdog: $cmd" ;;
esac
grep -q 'WARNING.*no-progress-timeout' "$TMP/scope.err" && bad "default flags warn about the idle limit (a unit or comparison slip)" \
  || pass "default flags: no idle-limit warning"
case "$(cfg_val "$OUT" reporters)" in *'"progress-append-only"'*) pass "config: progress-append-only reporter gives the watchdog its heartbeat" ;;
  *) bad "config: reporters=$(cfg_val "$OUT" reporters) — no heartbeat for the watchdog" ;; esac
[ "$(cfg_val "$OUT" dryRunTimeoutMinutes)" = 5 ] && pass "config: dryRunTimeoutMinutes=5 stated, not left to Stryker's default" \
  || bad "config: dryRunTimeoutMinutes=$(cfg_val "$OUT" dryRunTimeoutMinutes)"

run_scope --file apps/a/src/x.ts --no-progress-timeout 1200 --dry-run-timeout-min 2
case "$(kv1 "$OUT" run_command)" in *"--idle-timeout 1200 --"*) pass "--no-progress-timeout 1200 reaches the watchdog" ;;
  *) bad "--no-progress-timeout not passed: $(kv1 "$OUT" run_command)" ;; esac
[ "$(cfg_val "$OUT" dryRunTimeoutMinutes)" = 2 ] && pass "--dry-run-timeout-min 2 reaches the config" \
  || bad "--dry-run-timeout-min: $(cfg_val "$OUT" dryRunTimeoutMinutes)"
for bad_args in "--no-progress-timeout 0" "--no-progress-timeout x" "--dry-run-timeout-min 0"; do
  before="$(written)"
  # shellcheck disable=SC2086  # the row is a word list on purpose
  scope --runner vitest --file apps/a/src/x.ts $bad_args >/dev/null; rc=$?
  [ "$rc" = 2 ] && [ "$(written)" = "$before" ] && pass "[$bad_args] → 2, nothing written" || bad "[$bad_args] gave rc=$rc"
done
# The initial run prints nothing; an idle limit shorter than it aborts every healthy run.
scope --runner vitest --file apps/a/src/x.ts --no-progress-timeout 200 --dry-run-timeout-min 5 >/dev/null
grep -q 'WARNING.*--no-progress-timeout 200.*initial' "$TMP/scope.err" && pass "warns when the idle limit is shorter than the silent initial run" \
  || bad "no warning for idle 200 s < dry run 300 s: $(head -c 300 "$TMP/scope.err")"
scope --runner vitest --file apps/a/src/x.ts --no-progress-timeout 400 --timeout-ms 600000 >/dev/null
grep -q 'WARNING.*--no-progress-timeout 400.*mutant' "$TMP/scope.err" && pass "warns when one slow mutant can outlast the idle limit (a false 124)" \
  || bad "no warning for idle 400 s < mutant timeout 600 s: $(head -c 300 "$TMP/scope.err")"
G="$TMP/ignored"; mkdir -p "$G/src" && git init -q "$G"
printf '{"name":"g","devDependencies":{"vitest":"^4"}}\n' > "$G/package.json"; printf 'export const g = 1;\n' > "$G/src/g.ts"
printf '.stryker-scoped-*\n' > "$G/.gitignore"
GIT_CONFIG_GLOBAL=/dev/null git -C "$G" add -A && GIT_CONFIG_GLOBAL=/dev/null git -C "$G" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm init
(cd "$G" && bash "$STRYKER" --repo "$G" --diff HEAD --whole-files --runner vitest --file src/g.ts >/dev/null 2>"$TMP/ign.err")
grep -q 'WARNING.*git-ignored' "$TMP/ign.err" && pass "warns when the repo ignores .stryker-scoped-* (rt would not sync the run files)" \
  || bad "no warning for an ignored .stryker-scoped-*: $(head -c 300 "$TMP/ign.err")"
# run_command is executed by a shell: a repo path with a space must still land in the repo.
SP="$TMP/sp ace"; mkdir -p "$SP/src" "$TMP/fakebin"
printf '{"name":"s","devDependencies":{"vitest":"^4"}}\n' > "$SP/package.json"; printf 'export const s = 1;\n' > "$SP/src/s.ts"
printf '#!/bin/sh\npwd > "%s/npx.cwd"\n' "$TMP" > "$TMP/fakebin/npx"; chmod +x "$TMP/fakebin/npx"
cmd_sp="$(cd "$SP" && bash "$STRYKER" --repo "$SP" --whole-files --runner vitest --file src/s.ts 2>/dev/null | sed -n 's/^run_command=//p')"
(cd / && PATH="$TMP/fakebin:$PATH" bash -c "$cmd_sp" >/dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/npx.cwd" 2>/dev/null)" = "$SP" ] \
  && pass "run_command: a repo path with a space is quoted (npx ran in the repo)" \
  || bad "run_command with a spaced repo path: rc=$rc cwd=$(cat "$TMP/npx.cwd" 2>/dev/null) cmd=$cmd_sp"
NOWD="$TMP/nowd"; mkdir -p "$NOWD/lib" && cp "$STRYKER" "$NOWD/" && cp "$LIB" "$NOWD/lib/"
before="$(written)"
(cd "$M" && bash "$NOWD/stryker-scoped-config.sh" --repo "$M" --whole-files --runner vitest --file apps/a/src/x.ts >/dev/null 2>"$TMP/nowd.err"); rc=$?
[ "$rc" = 2 ] && [ "$(written)" = "$before" ] && grep -q 'stryker-run-watchdog.sh' "$TMP/nowd.err" \
  && pass "scoper without the watchdog beside it: exit 2, never an unwatched run_command" \
  || bad "scoper without watchdog: rc=$rc err=$(head -c 200 "$TMP/nowd.err")"

# ── portability: what the config carries must hold on the farm, where `rt` mirrors the repo elsewhere ──
# Bug: jsonReporter.fileName was the absolute local path, so on the farm the json reporter failed in
# wrapUp ("EACCES: mkdir '/Users'") and the report was lost while the run still exited 0.
cfg_of() { sed -n 's/^config_path=//p' <<<"$1"; }
out="$(scope --runner vitest --file apps/a/src/x.ts)"; cfg="$(cfg_of "$out")"
name="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).jsonReporter.fileName)' "$cfg" 2>/dev/null)"
case "$name" in ./.stryker-scoped-*.report.json) pass "portable: the default report path in the config is repo-relative ($name)" ;;
  *) bad "portable: jsonReporter.fileName is '$name', want ./.stryker-scoped-<tag>.report.json" ;; esac
grep -qF -- "$M" "$cfg" && bad "portable: the generated config still names the local repo path $M" \
  || pass "portable: no value in the generated config names the local repo path"
case "$(sed -n 's/^run_command=//p' <<<"$out")" in *"npx stryker run ./.stryker-scoped-"*.conf.json\)) pass "portable: run_command passes the config repo-relative" ;;
  *) bad "portable: run_command=$(sed -n 's/^run_command=//p' <<<"$out")" ;; esac
[ "$(sed -n 's/^report_path=//p' <<<"$out")" = "$M/${name#./}" ] && pass "portable: report_path is still printed absolute, for reading it here" \
  || bad "portable: report_path=$(sed -n 's/^report_path=//p' <<<"$out")"
# A relative --report/--out means the invocation's CWD; inside the repo it is written repo-relative.
mkdir -p "$M/apps/a/sub"
out="$(cd "$M/apps/a/sub" && bash "$STRYKER" --repo "$M" --whole-files --runner vitest --file apps/a/src/x.ts \
  --report ./r.json --out ./c.json 2>"$TMP/scope.err")"; rc=$?
name="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).jsonReporter.fileName)' "$M/apps/a/sub/c.json" 2>/dev/null)"
{ [ "$rc" = 0 ] && [ "$name" = ./apps/a/sub/r.json ] && [ "$(sed -n 's/^report_path=//p' <<<"$out")" = "$M/apps/a/sub/r.json" ] \
  && case "$(sed -n 's/^run_command=//p' <<<"$out")" in *"npx stryker run ./apps/a/sub/c.json)") true ;; *) false ;; esac; } \
  && pass "portable: relative --report/--out from a subdirectory resolve there and are written repo-relative" \
  || bad "portable: subdir --report/--out: rc=$rc fileName=$name out=$(tr '\n' ' ' <<<"$out" | head -c 400)"
# --repo through a symlink while the CWD is the physical path: still repo-relative, not the absolute fallback.
ln -s "$M" "$TMP/mono-link"
out="$(cd "$M/apps/a/sub" && bash "$STRYKER" --repo "$TMP/mono-link" --whole-files --runner vitest --file apps/a/src/x.ts \
  --report ./r2.json 2>"$TMP/scope.err")"; rc=$?; cfg="$(cfg_of "$out")"
name="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).jsonReporter.fileName)' "$cfg" 2>/dev/null)"
[ "$rc" = 0 ] && [ "$name" = ./apps/a/sub/r2.json ] && pass "portable: a symlinked --repo with a physical CWD still writes the report repo-relative" \
  || bad "portable: symlinked --repo: rc=$rc fileName='$name'"
# The same with a report directory that does not exist yet: the missing part joins the physical ancestor.
out="$(cd "$M/apps/a/sub" && bash "$STRYKER" --repo "$TMP/mono-link" --whole-files --runner vitest --file apps/a/src/x.ts \
  --report ./new/r3.json 2>"$TMP/scope.err")"; rc=$?; cfg="$(cfg_of "$out")"
name="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).jsonReporter.fileName)' "$cfg" 2>/dev/null)"
[ "$rc" = 0 ] && [ "$name" = ./apps/a/sub/new/r3.json ] && pass "portable: a not-yet-created report dir under a symlinked --repo is still repo-relative" \
  || bad "portable: symlinked --repo + new report dir: rc=$rc fileName='$name'"
# Outside the repo the operator chose a local file: it stays absolute.
mkdir -p "$TMP/reports"
out="$(scope --runner vitest --file apps/a/src/x.ts --report "$TMP/reports/r.json")"; cfg="$(cfg_of "$out")"
name="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).jsonReporter.fileName)' "$cfg" 2>/dev/null)"
[ "$name" = "$TMP/reports/r.json" ] && pass "portable: a --report outside the repo stays absolute" \
  || bad "portable: outside --report written as '$name'"

# ── F. a config that is multi-project AT RUNTIME, and a vitest-runner that cannot filter per test ─
# Defect 1 (2026-10-20, apps/runner): `test.projects: [{extends:true, test:{…}}, …]` — the projects are
# defined IN the config — made the scoper exit 5 and every hand-built config report "Ran 0.00 tests
# per mutant" with all mutants SURVIVED, even a control mutant a hand edit killed.
I="$TMP/inline"
mkdir -p "$I/apps/runner/src/__tests__"
printf '{"name":"i","private":true,"devDependencies":{"vitest":"^4"}}\n' > "$I/package.json"
printf '{"name":"r","private":true}\n' > "$I/apps/runner/package.json"
cat > "$I/apps/runner/vitest.config.ts" <<'EOF'
import { defineConfig } from 'vitest/config';
import path from 'path';
const srcDir = path.resolve(__dirname, 'src');
export default defineConfig({
  test: {
    root: srcDir,
    environment: 'happy-dom',
    setupFiles: ['./test-setup.ts'],
    projects: [
      { extends: true, test: { name: 'dom', include: ['**/*.dom.test.ts'] } },
      { extends: true, test: { name: 'node', environment: 'node', include: ['**/*.node.test.ts'], exclude: ['**/*.slow.ts'] } },
    ],
  },
});
EOF
printf 'export const x = 1;\n' > "$I/apps/runner/src/x.ts"
printf 'export const x = 1;\n' > "$I/apps/runner/src/x.test.ts"
out_i="$(cd "$I" && bash "$STRYKER" --repo "$I" --whole-files --runner vitest --file apps/runner/src/x.ts 2>"$TMP/inline.err")"; rc=$?
if [ "$rc" = 0 ] && [ "$(kv1 "$out_i" vitest_config)" = apps/runner/vitest.config.ts ] \
   && [ "$(kv1 "$out_i" vitest_include_source)" = colocated ] && [ "$(kvs "$out_i" vitest_include)" = src/x.test.ts ] \
   && [ "$(kv1 "$out_i" vitest_covering)" = apps/runner/src/x.test.ts ] \
   && [ "$(kv1 "$out_i" vitest_projects_dropped)" = apps/runner/vitest.config.ts:projects:2 ] \
   && grep -q 'WARNING apps/runner/vitest.config.ts declares test.projects' "$TMP/inline.err" \
   && grep -qF 'const { projects, workspace, ...narrow } = b.test ?? {};' "$I/$(configfile_of "$out_i")"; then
  pass "inline test.projects (the apps/runner shape): narrowed, dropped loudly, with the co-located test and its root"
else
  bad "inline projects: rc=$rc config=$(kv1 "$out_i" vitest_config) source=$(kv1 "$out_i" vitest_include_source) include=[$(kvs "$out_i" vitest_include | tr '\n' ' ')] dropped=$(kv1 "$out_i" vitest_projects_dropped) — $(head -c 300 "$TMP/inline.err")"
fi
# The same config with projects pointing at OTHER files stays refused: nothing here can narrow them.
mkdir -p "$I/apps/other"
printf "export default { test: { projects: ['apps/other/vitest.config.ts'] } };\n" > "$I/apps/runner-glob.config.ts"
printf 'export default {};\n' > "$I/apps/other/vitest.config.ts"
(cd "$I" && bash "$STRYKER" --repo "$I" --whole-files --runner vitest --file apps/runner/src/x.ts \
  --vitest-config apps/runner-glob.config.ts >/dev/null 2>"$TMP/glob.err"); rc=$?
[ "$rc" = 2 ] && grep -q 'fans out to projects it does not define' "$TMP/glob.err" \
  && pass "projects naming other config files: still refused (2), naming the reason" \
  || bad "projects naming other files: rc=$rc — $(head -c 300 "$TMP/glob.err")"

# Defect 2 (2026-10-20, apps/api): vitest 5 builds a full test name with " > ", the vitest-runner's
# per-test filter with " ". Every test is skipped, every mutant runs 0 tests and is reported SURVIVED.
mkdir -p "$SEP/apps/api/src"
printf '{"name":"s","private":true,"devDependencies":{"vitest":"5.0.5"}}\n' > "$SEP/package.json"
printf "export default { test: { include: ['**/*.spec.ts'] } };\n" > "$SEP/apps/api/vitest.config.ts"
printf 'export const f = 1;\n' > "$SEP/apps/api/src/f.ts"
printf 'export const f = 1;\n' > "$SEP/apps/api/src/f.spec.ts"
out_s="$(cd "$SEP" && bash "$STRYKER" --repo "$SEP" --whole-files --runner vitest --file apps/api/src/f.ts 2>"$TMP/sep.err")"; rc=$?
cmd="$(node -e 'const c=require(process.argv[1]); process.stdout.write((c.commandRunner||{}).command||"")' "$(kv1 "$out_s" config_path)" 2>/dev/null)"
cfg_lacks() { node -e 'const c=require(process.argv[1]); process.exit(process.argv[2] in c ? 1 : 0)' "$(kv1 "$1" config_path)" "$2"; }
if [ "$rc" = 0 ] && [ "$(kv1 "$out_s" test_runner)" = command ] && [ "$(kv1 "$out_s" coverage_analysis)" = off ] \
   && [ "$(kv1 "$out_s" ignore_static)" = false ] && [ "$(kv1 "$out_s" guard_module)" = none ] \
   && grep -q 'vitest 5.0.5' "$TMP/sep.err" && grep -q 'vitest-runner 10.0.0' "$TMP/sep.err" \
   && [ "$(cfg_val "$out_s" testRunner)" = '"command"' ] && cfg_lacks "$out_s" vitest \
   && case "$cmd" in *"npx vitest run --config ./.stryker-scoped-"*"--maxWorkers=1"*"apps/api/src/f.spec.ts"*) true ;; *) false ;; esac; then
  pass "separator mismatch (vitest \" > \" vs runner \" \"): test_runner=command, the project's own Vitest command, said loudly"
else
  bad "separator mismatch: rc=$rc runner=$(kv1 "$out_s" test_runner) coverage=$(kv1 "$out_s" coverage_analysis) command=[$cmd] — $(head -c 300 "$TMP/sep.err")"
fi
# The same packages, agreeing: the plugin runner stays, and the zero-tests guard is wired beside it.
# A stub @stryker-mutator/api/plugin lets the generated guard be RUN below, as Stryker loads it.
mkdir -p "$TMP/sep-ok/node_modules/@stryker-mutator/api"
printf '{"name":"@stryker-mutator/api","version":"10.0.0","exports":{"./plugin":"./plugin.mjs"}}\n' \
  > "$TMP/sep-ok/node_modules/@stryker-mutator/api/package.json"
printf 'export const PluginKind = { Reporter: "Reporter" };\nexport const declareClassPlugin = (kind, name, injectableClass) => ({ kind, name, injectableClass });\n' \
  > "$TMP/sep-ok/node_modules/@stryker-mutator/api/plugin.mjs"
cp -R "$SEP/apps" "$SEP/package.json" "$TMP/sep-ok/" \
  || bad "fixture: could not copy the agreeing-separators tree into $TMP/sep-ok"
out_k="$(cd "$TMP/sep-ok" && bash "$STRYKER" --repo "$TMP/sep-ok" --whole-files --runner vitest --file apps/api/src/f.ts 2>"$TMP/ok.err")"; rc=$?
guard_rel="$(kv1 "$out_k" guard_module)"
if [ "$rc" = 0 ] && [ "$(kv1 "$out_k" test_runner)" = vitest ] && [ "$(kv1 "$out_k" coverage_analysis)" = perTest ] \
   && [ "$(kv1 "$out_k" ignore_static)" = true ] && case "$guard_rel" in ./.stryker-scoped-*.zero-tests-guard.mjs) true ;; *) false ;; esac \
   && [ "$(cfg_val "$out_k" vitest)" = "{\"configFile\":\"$(configfile_of "$out_k")\"}" ] \
   && node -e 'const c=require(process.argv[1]);
       const ok = c.reporters.includes("zuvo-zero-tests-guard") && c.plugins.includes("@stryker-mutator/*")
         && c.plugins.includes("./" + process.argv[2].replace(/^\.\//, ""));
       process.exit(ok ? 0 : 1)' "$(kv1 "$out_k" config_path)" "$guard_rel"; then
  pass "matching separators: the plugin runner stays, and the zero-tests guard is a plugin + reporter of the config"
else
  bad "matching separators: rc=$rc runner=$(kv1 "$out_k" test_runner) guard=$guard_rel — $(head -c 300 "$TMP/ok.err")"
fi
# The guard itself, loaded the way Stryker loads it: a Killed/Survived mutant with 0 tests must make
# the process exit non-zero (a reporter's throw is swallowed by Stryker's BroadcastReporter, so the
# guard marks process.exitCode instead), and a healthy report must not.
run_guard() {  # $1 = report JSON; prints the child's exit code
  node --input-type=module - "$TMP/sep-ok/${guard_rel#./}" "$1" <<'EOF'
import { pathToFileURL } from 'node:url';
const [guardPath, reportJson] = process.argv.slice(2);
const m = await import(pathToFileURL(guardPath).href);
const plugin = m.strykerPlugins[0];
if (plugin.name !== 'zuvo-zero-tests-guard' || plugin.kind !== 'Reporter') { console.error('NOT A GUARD PLUGIN'); process.exit(3); }
const reporter = new plugin.injectableClass();
reporter.onMutationTestReportReady(JSON.parse(reportJson));
// Stryker reports through a BroadcastReporter, which SWALLOWS a reporter's throw: the exit code a
// real run sees is process.exitCode, so the harness reproduces that and nothing else.
try { reporter.wrapUp(); } catch (e) { console.error('THREW (swallowed by Stryker): ' + e.message); }
process.exit(process.exitCode || 0);
EOF
}
broken='{"files":{"a.ts":{"mutants":[{"status":"Survived","testsCompleted":0,"mutatorName":"X","location":{"start":{"line":1}}}]}}}'
broken_killed='{"files":{"a.ts":{"mutants":[{"status":"Killed","testsCompleted":0,"mutatorName":"X","location":{"start":{"line":1}}}]}}}'
healthy='{"files":{"a.ts":{"mutants":[{"status":"Killed","testsCompleted":3,"mutatorName":"X","location":{"start":{"line":1}}}]}}}'
run_guard "$broken" >/dev/null 2>"$TMP/guard.err"; rc=$?
[ "$rc" = 1 ] && grep -q 'zuvo-zero-tests-guard: 1 of 1 Killed/Survived mutant(s) ran 0 tests' "$TMP/guard.err" \
  && pass "zero-tests guard: a mutant decided with 0 tests fails the run (exit 1) and names it" \
  || bad "zero-tests guard (broken report): rc=$rc — $(head -c 300 "$TMP/guard.err")"
# A bogus KILL with no tests is the same defect from the other side (a filter bug that "kills" mutants).
run_guard "$broken_killed" >/dev/null 2>"$TMP/guard-kill.err"; rc=$?
[ "$rc" = 1 ] && grep -q '1 of 1 Killed/Survived mutant(s) ran 0 tests' "$TMP/guard-kill.err" \
  && pass "zero-tests guard: a Killed mutant with 0 tests fails the run too (not only Survived)" \
  || bad "zero-tests guard (killed, 0 tests): rc=$rc — $(head -c 300 "$TMP/guard-kill.err")"
run_guard "$healthy" >/dev/null 2>"$TMP/guard-ok.err"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$TMP/guard-ok.err" ] \
  && pass "zero-tests guard: a healthy report passes untouched" \
  || bad "zero-tests guard (healthy report): rc=$rc — $(head -c 300 "$TMP/guard-ok.err")"
# --coverage other than perTest with ignoreStatic (the default) is still a startup error — now checked
# where the runner is known (the vitest fallback forces off/false, an explicit --coverage does not).
(cd "$TMP/sep-ok" && bash "$STRYKER" --repo "$TMP/sep-ok" --whole-files --runner vitest --file apps/api/src/f.ts \
  --coverage off >/dev/null 2>"$TMP/cov.err"); rc=$?
[ "$rc" = 2 ] && grep -q 'cannot be combined with ignoreStatic' "$TMP/cov.err" \
  && pass "--coverage off without --include-static: exit 2, named (not a Stryker startup failure)" \
  || bad "--coverage off without --include-static: rc=$rc — $(head -c 300 "$TMP/cov.err")"

# ── G. the preflight: the same decision where the run happens ─────────────────────────────────
# The scoper is run in a worktree with no node_modules (the farm installs them afterwards), so a
# vitest-runner/vitest mismatch — or TypeScript 7 — is only visible at run time. The generated
# preflight decides there, rewrites the config, and refuses a command run that runs 0 tests.
#
# A `npx` that answers like Vitest: $1 = the "Tests" line, $2 = exit code, $3 = marker file (written
# when called, so "did it even run" is assertable), $5 = when set, answer through a JSON report
# instead of the text summary (a repo reporter can suppress/reshape that line).
mk_npx() {
  local bin="$TMP/bin-$4"; mkdir -p "$bin"
  if [ -n "${5:-}" ]; then
    cat > "$bin/npx" <<EOF
#!/usr/bin/env bash
: > '$3'
for a in "\$@"; do case "\$a" in --outputFile=*) printf '{"numPassedTests":$5,"numFailedTests":0}\n' > "\${a#--outputFile=}" ;; esac; done
printf ' RUN  v5.0.5 /repo\n\n Duration  100ms\n'
exit $2
EOF
  else
    cat > "$bin/npx" <<EOF
#!/usr/bin/env bash
: > '$3'
# Vitest colours its summary even when its output is not a TTY — the real farm output.
printf ' RUN  v5.0.5 /repo\n\n Test Files \033[22m \033[1m\033[32m1 passed\033[39m\033[22m \033[90m(1)\033[39m\n      \033[22m \033[1m\033[32m$1\033[39m\033[22m \033[90m(1)\033[39m\n\n Duration  100ms\n'
exit $2
EOF
  fi
  chmod +x "$bin/npx"; printf '%s' "$bin"
}
PASSBIN="$(mk_npx 'Tests  3 passed (3)' 0 "$TMP/npx-ran-ok" ok)"
ZEROBIN="$(mk_npx 'Tests  no tests' 1 "$TMP/npx-ran-zero" zero)"
JSONBIN="$(mk_npx '' 0 "$TMP/npx-ran-json" json 2)"
preflight_of() { (cd "$1" && PATH="$2:$PATH" node "$3" 2>&1); }   # $3 = ./preflight_module of the kv

# G1. Emission with no node_modules: the decision is deferred, not guessed, and the run carries the
#     preflight and the in-place list (TypeScript is declared: it may be 7 where the run happens).
FL="$TMP/flip"; mkdir -p "$FL/apps/api/src"
printf '{"name":"f","private":true,"devDependencies":{"typescript":"^7","vitest":"5.0.5"}}\n' > "$FL/package.json"
printf "export default { test: { include: ['**/*.spec.ts'] } };\n" > "$FL/apps/api/vitest.config.ts"
printf 'export const f = 1;\n' > "$FL/apps/api/src/f.ts"
printf 'export const f = 1;\n' > "$FL/apps/api/src/f.spec.ts"
out_fl="$(cd "$FL" && bash "$STRYKER" --repo "$FL" --whole-files --runner vitest --file apps/api/src/f.ts 2>"$TMP/flip.err")"; rc=$?
pf="$(kv1 "$out_fl" preflight_module)"
case "$(kv1 "$out_fl" run_command)" in *"--in-place-files ./.stryker-scoped-"*"--preflight $pf "*) cmd_ok=1 ;; *) cmd_ok=0 ;; esac
if [ "$rc" = 0 ] && [ "$(kv1 "$out_fl" test_runner)" = vitest ] \
   && [ "$(kv1 "$out_fl" in_place)" = false ] && grep -q 'deferred to the preflight' <<<"$(kv1 "$out_fl" in_place_reason)" \
   && case "$pf" in ./.stryker-scoped-*.preflight.mjs) true ;; *) false ;; esac \
   && [ -f "$FL/${pf#./}" ] && [ -f "$FL/$(sed -n 's/.*--in-place-files \.\/\([^ ]*\).*/\1/p' <<<"$(kv1 "$out_fl" run_command)")" ] \
   && [ "$cmd_ok" = 1 ]; then
  pass "preflight (no node_modules): runner decision deferred, run_command carries --preflight and the in-place list"
else
  bad "preflight emission: rc=$rc runner=$(kv1 "$out_fl" test_runner) in_place=$(kv1 "$out_fl" in_place) reason=$(kv1 "$out_fl" in_place_reason) cmd=$(kv1 "$out_fl" run_command) — $(head -c 300 "$TMP/flip.err")"
fi
conf_fl="$(kv1 "$out_fl" config_path)"

# G2. The packages arrive (vitest 5 " > " vs runner " "): the preflight rewrites the config to the
#     project's own command, drops the guard (its reporter counts testsCompleted, meaningless there),
#     and proves the command actually executes tests.
cp -R "$SEP/node_modules" "$FL/node_modules"
pre_out="$(preflight_of "$FL" "$PASSBIN" "$pf")"; rc=$?
if [ "$rc" = 0 ] && grep -q 'test_runner=command: vitest 5.0.5 joins test names with " > "' <<<"$pre_out" \
   && grep -q 'command runner verified: 3 test(s)' <<<"$pre_out" \
   && node -e 'const c=require(process.argv[1]);
       const ok = c.testRunner === "command" && c.coverageAnalysis === "off" && c.ignoreStatic === false
         && !("vitest" in c) && !c.plugins.some((p) => /zero-tests-guard/.test(p)) && !c.reporters.includes("zuvo-zero-tests-guard")
         && /npx vitest run --config \.\/\.stryker-scoped-.*--maxWorkers=1 .*apps\/api\/src\/f\.spec\.ts/.test((c.commandRunner||{}).command||"");
       process.exit(ok ? 0 : 1)' "$conf_fl"; then
  pass "preflight: a run-time separator mismatch falls back to testRunner command, guard removed, tests proven"
else
  bad "preflight mismatch: rc=$rc out=$(head -c 400 <<<"$pre_out")"
fi

# G3. A command that runs 0 tests must abort the run: 0 tests per mutant reads as KILLED for every
#     mutant. A FRESH emission (not the one G2 already rewrote): a config that is already a command at
#     emission time must be verified just the same.
FR="$TMP/flip-cmd"; rm -rf "$FR"; cp -R "$FL" "$FR"; rm -f "$FR"/.stryker-scoped-*
out_fr="$(cd "$FR" && bash "$STRYKER" --repo "$FR" --whole-files --runner vitest --file apps/api/src/f.ts 2>/dev/null)"
rm -f "$TMP/npx-ran-zero"
pre_out="$(preflight_of "$FR" "$ZEROBIN" "$(kv1 "$out_fr" preflight_module)")"; rc=$?
[ "$(kv1 "$out_fr" test_runner)" = command ] && [ "$rc" = 1 ] && grep -q 'the command runner ran no test(s)' <<<"$pre_out" && [ -f "$TMP/npx-ran-zero" ] \
  && pass "preflight: a command run that executes 0 tests aborts (exit 1) instead of reporting a fake score" \
  || bad "preflight 0 tests: rc=$rc runner=$(kv1 "$out_fr" test_runner) ran=$([ -f "$TMP/npx-ran-zero" ] && echo yes || echo no) — $(head -c 300 <<<"$pre_out")"
# The same fresh command run, proven through its JSON report: a repo reporter that suppresses the
# "Tests" summary line must not make executed tests read as 0.
rm -f "$TMP/npx-ran-json"
pre_out="$(preflight_of "$FR" "$JSONBIN" "$(kv1 "$out_fr" preflight_module)")"; rc=$?
[ "$rc" = 0 ] && grep -q 'command runner verified: 2 test(s) ran (exit 0, json)' <<<"$pre_out" && [ -f "$TMP/npx-ran-json" ] \
  && pass "preflight: the test count comes from Vitest's JSON report, not only its text summary" \
  || bad "preflight json: rc=$rc — $(head -c 300 <<<"$pre_out")"

# G4. TypeScript 7 where the run happens: in-place, and the tsconfig preprocessor turned off by pointing
#     tsconfigFile at a file that does not exist. Uses a fresh emission (G2 already rewrote the config).
TSF="$TMP/tsflip"; cp -R "$FL" "$TSF"; rm -rf "$TSF/node_modules"; rm -f "$TSF"/.stryker-scoped-*
out_ts="$(cd "$TSF" && bash "$STRYKER" --repo "$TSF" --whole-files --runner vitest --file apps/api/src/f.ts 2>/dev/null)"
mkdir -p "$TSF/node_modules/typescript"
printf '{"name":"typescript","version":"7.0.2","main":"lib/typescript.js"}\n' > "$TSF/node_modules/typescript/package.json"
mkdir -p "$TSF/node_modules/typescript/lib" && printf 'module.exports = { version: "7.0.2" };\n' > "$TSF/node_modules/typescript/lib/typescript.js"
pre_out="$(preflight_of "$TSF" "$PASSBIN" "$(kv1 "$out_ts" preflight_module)")"; rc=$?
[ "$rc" = 0 ] && grep -q 'in-place: typescript 7.0.2 has no parseConfigFileTextToJson' <<<"$pre_out" \
  && node -e 'const c=require(process.argv[1]); process.exit(c.inPlace === true && /^\.stryker-scoped-.*no-tsconfig\.json$/.test(c.tsconfigFile||"") ? 0 : 1)' "$(kv1 "$out_ts" config_path)" \
  && pass "preflight: TypeScript 7 found at run time switches the run in-place and disables the preprocessor" \
  || bad "preflight TypeScript 7: rc=$rc — $(head -c 300 <<<"$pre_out")"

# G5. Packages that agree: nothing is rewritten and the project's command is not run.
OKF="$TMP/okflip"; cp -R "$FL" "$OKF"; rm -rf "$OKF/node_modules"; rm -f "$OKF"/.stryker-scoped-*
out_ok="$(cd "$OKF" && bash "$STRYKER" --repo "$OKF" --whole-files --runner vitest --file apps/api/src/f.ts 2>/dev/null)"
cp -R "$TMP/sep-ok/node_modules" "$OKF/node_modules"
rm -f "$TMP/npx-ran-ok"
pre_out="$(preflight_of "$OKF" "$PASSBIN" "$(kv1 "$out_ok" preflight_module)")"; rc=$?
[ "$rc" = 0 ] && grep -q 'the plugin runner filters per test' <<<"$pre_out" && [ ! -f "$TMP/npx-ran-ok" ] \
  && node -e 'const c=require(process.argv[1]); process.exit(c.testRunner === "vitest" && c.ignoreStatic === true ? 0 : 1)' "$(kv1 "$out_ok" config_path)" \
  && pass "preflight: matching separators keep the plugin runner, the config untouched and no test run" \
  || bad "preflight agree: rc=$rc npx-ran=$([ -f "$TMP/npx-ran-ok" ] && echo yes || echo no) — $(head -c 300 <<<"$pre_out")"

if [ "$fail" = 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
