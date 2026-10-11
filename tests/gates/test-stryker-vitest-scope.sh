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
printf "const shared = { projects: ['a'] };\nexport default { test: shared };\n" > "$F/opaque.config.ts"
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

ALONE="$TMP/alone"; mkdir -p "$ALONE" && cp "$STRYKER" "$ROOT/scripts/stryker-run-watchdog.sh" "$ALONE/"
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
  "(cd $M && bash ./.stryker-scoped-"*".watchdog.sh --idle-timeout 600 -- npx stryker run "*")")
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
NOWD="$TMP/nowd"; mkdir -p "$NOWD/lib" && cp "$STRYKER" "$NOWD/" && cp "$ROOT/scripts/lib/stryker-vitest.cjs" "$NOWD/lib/"
before="$(written)"
(cd "$M" && bash "$NOWD/stryker-scoped-config.sh" --repo "$M" --whole-files --runner vitest --file apps/a/src/x.ts >/dev/null 2>"$TMP/nowd.err"); rc=$?
[ "$rc" = 2 ] && [ "$(written)" = "$before" ] && grep -q 'stryker-run-watchdog.sh' "$TMP/nowd.err" \
  && pass "scoper without the watchdog beside it: exit 2, never an unwatched run_command" \
  || bad "scoper without watchdog: rc=$rc err=$(head -c 200 "$TMP/nowd.err")"

if [ "$fail" = 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
