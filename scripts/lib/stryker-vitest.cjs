'use strict';
// stryker-vitest.cjs — which Vitest config a scoped Stryker run belongs to, which tests cover it,
// and the narrowed config Stryker runs (RD-121). Pure; paths are repo-relative POSIX.
const fs = require('fs');
const path = require('path');

const CONFIG_NAMES = ['vitest.config.ts', 'vitest.config.mts', 'vitest.config.cts', 'vitest.config.js',
  'vitest.config.mjs', 'vitest.config.cjs', 'vite.config.ts', 'vite.config.mts', 'vite.config.cts',
  'vite.config.js', 'vite.config.mjs', 'vite.config.cjs'];
const WORKSPACE_FILES = ['vitest.workspace.ts', 'vitest.workspace.mts', 'vitest.workspace.js', 'vitest.workspace.json'];
const VITEST_DEFAULT_INCLUDE = '**/*.{test,spec}.?(c|m)[jt]s?(x)';
const TEST_EXT = '\\.[cm]?[jt]sx?$';
const MAX_COVERING_TESTS = 40;

const P = path.posix;
const exists = (repo, rel) => fs.existsSync(path.join(repo, rel));
const outsideRepo = (rel) => { const n = P.normalize(rel); return P.isAbsolute(n) || n === '..' || n.startsWith('../'); };
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// Vitest include entries are globs: `app/[id]/x.test.ts` would match `app/i/x.test.ts`. A backslash
// escape, not a `[c]` class: `[!]` and `[]]` are not literal characters in a glob class.
const escapeGlob = (p) => p.replace(/[*?[\]{}()!+@|\\]/g, '\\$&');

// Walk up from the file's directory to the repo root (never above it: a config outside the repo is
// outside Stryker's sandbox). In one directory a vitest.* config wins over a vite.* one.
function findNearestConfig(repo, relFile) {
  if (outsideRepo(relFile)) return null;
  let dir = P.dirname(relFile);
  for (;;) {
    const hit = CONFIG_NAMES.find((n) => exists(repo, P.join(dir, n)));
    if (hit) return P.join(dir, hit);
    if (dir === '.' || dir === '') return null;
    dir = P.dirname(dir);
  }
}

// A `/` opens a regex literal (not a division) after one of these, or at the start of the source.
const REGEX_PREFIX = new Set(['', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '>', '<', '+', '-', '*', '%', '~', '^']);
const REGEX_KEYWORDS = /(?:^|[^\w$])(?:return|typeof|case|in|of|void|yield|await|delete|throw|new)$/;

// Same length as `src`, with comments, string contents and regex-literal contents blanked (quotes
// kept), so the key scanner cannot be fooled by `// projects: …`, `/["]/` or a string holding `include:`.
function blank(src) {
  let out = '';
  let prev = '';
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    const n = src[i + 1];
    if (c === '/' && n === '/') { while (i < src.length && src[i] !== '\n') { out += ' '; i++; } if (i < src.length) out += '\n'; continue; }
    if (c === '/' && n === '*') {
      const e = src.indexOf('*/', i + 2); const end = e < 0 ? src.length : e + 2;
      out += src.slice(i, end).replace(/[^\n]/g, ' '); i = end - 1; continue;
    }
    if (c === '/' && (REGEX_PREFIX.has(prev) || REGEX_KEYWORDS.test(out.trimEnd()))) {
      let j = i + 1; let cls = false;
      while (j < src.length && src[j] !== '\n' && (cls || src[j] !== '/')) {
        if (src[j] === '\\') j++; else if (src[j] === '[') cls = true; else if (src[j] === ']') cls = false;
        j++;
      }
      out += '/' + ' '.repeat(Math.max(0, j - i - 1)) + (j < src.length ? src[j] : ''); i = j; prev = '/'; continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      out += c; i++;
      while (i < src.length && src[i] !== c) { if (src[i] === '\\') { out += ' '; i++; } out += src[i] === '\n' ? '\n' : ' '; i++; }
      if (i < src.length) out += c;
      prev = c; continue;
    }
    out += c;
    if (!/\s/.test(c)) prev = c;
  }
  return out;
}

// Direct properties of every `test: { … }` object, as [{key: [start, end) | 'shorthand'}]. A key
// written shorthand (`{ projects }`) has a value this scanner cannot read. `coverage.include` sits one
// level deeper and is therefore never `include`.
function testObjects(src) {
  const b = blank(src);
  const objects = [];
  // Run on the blanked text, where a quoted 'test' key reads as quotes around 4 blanks; the source at
  // the same offset tells whether those blanks were `test`.
  const re = /(?:^|[^\w$.])(test|(['"]) {4}\2)\s*:\s*\{/g;
  let m;
  while ((m = re.exec(b))) {
    const at = m.index + m[0].indexOf(m[1]);
    if (!/^(?:test|'test'|"test")/.test(src.slice(at, at + 6))) continue;
    const keys = {};
    let depth = 0;
    let current = null;
    for (let i = m.index + m[0].length - 1; i < b.length; i++) {
      const c = b[i];
      if ('{[('.includes(c)) { depth++; if (depth === 1) continue; }
      if ('}])'.includes(c)) { depth--; if (depth === 0) { if (current) current[1] = i; break; } }
      if (depth === 1 && c === ',') { if (current) current[1] = i; current = null; continue; }
      if (depth !== 1 || current) continue;
      const rest = b.slice(i);
      const k = /^\s*(?:\.\.\.|([\w$]+|'[^']*'|"[^"]*")\s*:)/.exec(rest);
      if (k) {
        const raw = k[1] ? src.slice(i + k[0].indexOf(k[1]), i + k[0].indexOf(k[1]) + k[1].length) : '...';
        current = keys[raw.replace(/^['"]|['"]$/g, '')] = [i + k[0].length, b.length];
        i += k[0].length - 1;
      } else {
        const s = /^\s*([\w$]+)\s*(?=[,}])/.exec(rest);
        if (s) { keys[s[1]] = 'shorthand'; i += s[0].length - 1; }
      }
    }
    objects.push(keys);
  }
  return objects;
}

// True when the config declares projects in any form: `test.projects` / `test.workspace` in ANY test
// object, or a `vitest.workspace.*` file beside it.
function hasProjects(repo, relConfig) {
  return projectsForm(repo, relConfig).kind !== 'none';
}

// The entries of a literal array, as source slices, or null when the text is not one.
function literalArray(text) {
  const t = text.trim();
  if (t[0] !== '[' || t[t.length - 1] !== ']') return null;
  const body = t.slice(1, -1);
  const entries = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ',' && depth === 0) { entries.push(body.slice(start, i)); start = i + 1; }
  }
  entries.push(body.slice(start));
  return entries.map((e) => e.trim()).filter(Boolean);
}

const isProjectObject = (e) => /^\{[\s\S]*\}$/.test(e) || /^[\w$.]+\s*\(\s*\{[\s\S]*\}\s*\)$/.test(e);

// How a config fans out to projects:
//   none   — no test.projects/test.workspace anywhere and no vitest.workspace.* beside it.
//   inline — test.projects/test.workspace is a literal array of project OBJECTS defined in this same
//            file (`projects: [{ extends: true, test: { … } }, …]`). Dropping the key keeps every
//            test in this config's own tree; the project files of the repo's own Stryker configs are
//            dropped the same way. `why` names the key.
//   opaque — a variable/shorthand/spread, entries naming OTHER project files or globs
//            (`projects: ['apps/*']`), or a vitest.workspace.* file: the real project configs live
//            elsewhere and no include written here can narrow them.
function projectsForm(repo, relConfig) {
  const beside = WORKSPACE_FILES.find((n) => exists(repo, P.join(P.dirname(relConfig), n)));
  if (beside) return { kind: 'opaque', why: `a ${beside} file sits beside it` };
  const src = fs.readFileSync(path.join(repo, relConfig), 'utf8');
  const b = blank(src);
  // EVERY declaration is read, not the first one: a second `projects`/`workspace` key (another test
  // object, a different spelling) can still fan out after an inline array looked safe.
  let inline = null;
  for (const keys of testObjects(src)) {
    for (const key of ['projects', 'workspace']) {
      const span = keys[key];
      if (!span) continue;
      if (span === 'shorthand') return { kind: 'opaque', why: `test.${key} is written shorthand` };
      const entries = literalArray(b.slice(span[0], span[1]));
      if (!entries) return { kind: 'opaque', why: `test.${key} is not a literal array` };
      if (!entries.length) continue;   // `projects: []` fans out to nothing
      if (entries.every(isProjectObject)) {
        inline = { kind: 'inline', key: inline ? inline.key : key, count: (inline ? inline.count : 0) + entries.length };
        continue;
      }
      if (entries.some((e) => e.startsWith('...'))) return { kind: 'opaque', why: `test.${key} holds a spread` };
      return { kind: 'opaque', why: `test.${key} names project files or variables, not inline project objects` };
    }
  }
  return inline || { kind: 'none' };
}

// `test: shared`, `defineConfig({ test })`: the test options live elsewhere and cannot be read here.
const opaqueTest = (src) => /(?:^|[^\w$.])(?:test\s*:\s*[^\s{]|test\s*[,}])/.test(blank(src));

// The config's own `test.root`/`test.dir` when it is a literal string (the value is relative to the
// config's directory): the directory its setupFiles, include and globals are written against. A root
// built from a variable cannot be read here; the generated config then keeps it at run time.
function parseTestRoot(src) {
  if (opaqueTest(src)) return null;
  const objects = testObjects(src);
  if (objects.length !== 1) return null;
  const span = objects[0].root || objects[0].dir;
  if (!span || span === 'shorthand') return null;
  const text = src.slice(span[0], span[1]).trim();
  if (!/^(['"`])([^'"`\r\n]*)\1$/.test(text)) return null;
  const value = text.slice(1, -1);
  return value ? value : null;
}

// The config's own `test.include`: {kind:'list', globs} when it is a literal array of strings,
// {kind:'default'} when the config demonstrably sets none, {kind:'unknown'} when it cannot be read
// (a variable, a shorthand, several test objects, or an include merged in from elsewhere).
function parseTestInclude(src, key = 'include') {
  if (opaqueTest(src)) return { kind: 'unknown' };
  const objects = testObjects(src);
  const inherits = /\.\.\.|mergeConfig|extends/.test(blank(src));
  if (!objects.length) return inherits ? { kind: 'unknown' } : { kind: 'default' };
  if (objects.length > 1) return { kind: 'unknown' };
  const keys = objects[0];
  // Merged onto a base (mergeConfig concatenates arrays), the literal list is not the whole include.
  if (!keys[key]) return inherits ? { kind: 'unknown' } : { kind: 'default' };
  // A spread inside the object may overwrite the literal (`{ include: [...], ...base }`).
  if (keys[key] === 'shorthand' || keys['...'] || /mergeConfig|extends/.test(blank(src))) return { kind: 'unknown' };
  const [from, to] = keys[key];
  const b = blank(src);
  if (!/^\[\s*(?:(['"`])[^'"`]*\1\s*,\s*)*(?:(['"`])[^'"`]*\2\s*)?\]$/.test(b.slice(from, to).trim())) return { kind: 'unknown' };
  // String spans come from the BLANKED text (a quote in a comment is not one); their contents from
  // the original source at the same offsets.
  const globs = [];
  for (let i = from; i < to; i++) {
    if (!'\'"`'.includes(b[i])) continue;
    const j = b.indexOf(b[i], i + 1);
    if (j < 0 || j >= to) return { kind: 'unknown' };
    const text = src.slice(i + 1, j);
    if (b[i] === '`' && text.includes('${')) return { kind: 'unknown' };
    if (/[\r\n]/.test(text)) return { kind: 'unknown' };  // would break the key=value lines it is printed on
    globs.push(text.replace(/\\(.)/g, '$1').replace(/^\.\//, ''));
    i = j;
  }
  return { kind: 'list', globs };
}

const listDir = (repo, d) => (exists(repo, d) ? fs.readdirSync(path.join(repo, d)) : []);
const stripExt = (rel) => rel.replace(/\.[^./]+$/, '');
// A file Vitest would collect as a test from its NAME alone (`.test.`/`.spec.` before the extension).
const TEST_NAME = /\.(?:test|spec)\.[cm]?[jt]sx?$/;

// The module specifiers a file imports, as written: `from '…'`, `import '…'`, `require('…')`,
// `import('…')`. A side-effect import and a `vi.mock('…')` path count too: both make Vitest load the
// module, which is all "covering" means here.
function importSpecifiers(src) {
  const re = /(?:^|[^\w$.])(?:import|require|from)\s*\(?\s*(['"])([^'"\n]+)\1/g;
  const out = [];
  let m;
  while ((m = re.exec(src))) out.push(m[2]);
  return out;
}

// The stem of every path, extension dropped, so `./foo`, `./foo.js` (a TS ESM specifier) and
// `./foo.ts` all name the same module. A directory specifier resolves to its index file.
const moduleStem = (rel) => stripExt(P.normalize(rel)).replace(/\/index$/, '');

// Spec files in the source's own directory and its __tests__ that IMPORT the source. A sibling named
// `foo.checked-dsl.spec.ts` is found by name (colocatedTests); an importer named after something else
// (`compiler-variants.spec.ts` importing `./simple-script-compiler`) only by this scan. Relative
// specifiers only: resolving an alias (`@/…`) would mean reading the config's alias table, and a wrong
// resolution here would run an unrelated test.
function importingTests(repo, relFile) {
  const dir = P.dirname(relFile);
  const target = moduleStem(relFile);
  const hit = [];
  for (const d of [dir, P.join(dir, '__tests__')]) {
    for (const n of listDir(repo, d)) {
      if (!TEST_NAME.test(n)) continue;
      const t = P.join(d, n);
      let src;
      try { src = fs.readFileSync(path.join(repo, t), 'utf8'); } catch { continue; }
      const imports = importSpecifiers(src).some((s) =>
        s.startsWith('.') && moduleStem(P.join(P.dirname(t), s)) === target);
      if (imports) hit.push(t);
    }
  }
  return hit.sort();
}

// foo.test.* / foo.spec.* and foo.<variant>.test|spec.* beside the source, __tests__/foo[.<variant>]
// [.test|.spec].* (plus a bare __tests__/foo.* helper, which matchesOwnInclude then filters), and any
// spec/test file beside them that imports the source. The bare stem was the whole rule until
// 2026-10-20: a module with five sibling specs (simple-script-compiler.{,checked-dsl,legacy,
// rule-shape,page-target}.spec.ts) had one selected and reported 42 % from tests that never ran.
function colocatedTests(repo, relFile) {
  const dir = P.dirname(relFile);
  const stem = escapeRe(P.basename(relFile).replace(/\.[^.]+$/, ''));
  const beside = new RegExp(`^${stem}\\.(?:.+\\.)?(?:test|spec)${TEST_EXT}`);
  const nested = new RegExp(`^${stem}(?:\\.(?:.+\\.)?(?:test|spec))?${TEST_EXT}`);
  const byName = [
    ...listDir(repo, dir).filter((n) => beside.test(n)).map((n) => P.join(dir, n)),
    ...listDir(repo, P.join(dir, '__tests__')).filter((n) => nested.test(n)).map((n) => P.join(dir, '__tests__', n)),
  ];
  return [...new Set([...byName, ...importingTests(repo, relFile)])].sort();
}

// Nearest package.json directory: the workspace a file belongs to when its config is an aggregator.
function workspaceDir(repo, relFile) {
  let dir = P.dirname(relFile);
  while (dir !== '.' && dir !== '/' && dir !== '' && !exists(repo, P.join(dir, 'package.json'))) dir = P.dirname(dir);
  return dir;
}

// Which config the scope runs under, and which tests cover it. {groups} when no single config is
// honest (exit 5 at the caller), {error} for an input the config cannot serve (exit 2), else the
// resolution the scoper prints and renders. `override` and `tests` arrive repo-relative from the scoper.
function resolveVitest(args) {
  try { return resolve(args); } catch (e) {
    return { error: `cannot read a Vitest config (${e.path || 'unknown path'}): ${e.message}` };
  }
}

function resolve({ repo, files, override, tests }) {
  if (!files.length) return { error: 'no scoped files' };
  if ([...files, ...tests, override || '.'].some(outsideRepo)) return { error: 'a scoped file, test or --vitest-config resolves outside the repo' };
  if (override && !exists(repo, override)) return { error: `--vitest-config: no such file: ${override}` };
  let config = override || null;
  let dropped = null;
  if (override) {
    const form = projectsForm(repo, override);
    if (form.kind === 'opaque') {
      return { error: `--vitest-config ${override} fans out to projects it does not define (${form.why}): every project would run and no include can narrow it — pass the workspace's own config` };
    }
    if (form.kind === 'inline') dropped = { config: override, ...form };
  }
  if (!override) {
    const byConfig = group(files, (f) => findNearestConfig(repo, f) || 'none');
    if (byConfig.length > 1) return { groups: byConfig };
    config = byConfig[0].key === 'none' ? null : byConfig[0].key;
    if (config) {
      const form = projectsForm(repo, config);
      if (form.kind === 'opaque') {
        return { aggregator: config, why: form.why, groups: group(files, (f) => workspaceDir(repo, f)) };
      }
      if (form.kind === 'inline') dropped = { config, ...form };
    }
  }
  const src = config ? fs.readFileSync(path.join(repo, config), 'utf8') : '';
  // The directory test paths are relative to: the config's own test.root/test.dir when it declares a
  // literal one, else the config's directory.
  const declaredRoot = config ? parseTestRoot(src) : null;
  const root = declaredRoot ? P.normalize(P.join(P.dirname(config), declaredRoot)) : config ? P.dirname(config) : '.';
  const rel = (f) => (root === '.' ? f : P.relative(root, f));
  const own = config ? parseTestInclude(src) : { kind: 'default' };
  const ownExclude = config ? parseTestInclude(src, 'exclude') : { kind: 'default' };
  // `!pattern` (a re-include) is ignored: a re-included test may be dropped, never wrongly added.
  own.exclude = ownExclude.kind === 'list' ? ownExclude.globs.filter((g) => !g.startsWith('!')) : [];
  const warnings = [];
  // The keys are dropped by renderVitestConfig; say what that costs, loudly, BEFORE the run.
  if (dropped) {
    warnings.push(`${dropped.config} declares test.${dropped.key} (${dropped.count} inline project object(s)): the scoped run ` +
      'drops them, so their project-level test options (environment, setupFiles, include, exclude) do not apply — ' +
      `only ${dropped.config}'s own test options do`);
  }
  if (config && ownExclude.kind === 'unknown') {
    warnings.push(`${config} test.exclude cannot be read: co-located tests are not filtered by it`);
  }
  if (config && !dropped && !opaqueTest(src) && /mergeConfig|extends|\.\.\.\s*[\w$]+\s*[,}]/.test(blank(src))) {
    warnings.push(`${config} spreads or merges another config: whether it is multi-project cannot be read`);
  }
  if (config && opaqueTest(src)) {
    warnings.push(`${config} takes its test options from a variable: whether it is multi-project cannot be read`);
  }
  const setsRoot = config && testObjects(src).some((k) => k.root || k.dir);
  if (setsRoot || (config && /(?:^|[^\w$.])root\s*:/.test(blank(src)))) {
    warnings.push(`${config} sets a root/test.root/test.dir: the scoped run keeps it (its setupFiles and include ` +
      'are written against it) and states the tests in paths relative to it');
  }
  const out = { config: config || 'none', root, warnings, dropped };
  const away = files.filter((f) => outsideRepo(rel(f)));
  if (away.length) warnings.push(`scoped file(s) outside vitest_root ${root}: ${away.join(', ')} — only tests under ${root} can run`);
  if (tests.length) {
    const outside = tests.filter((t) => outsideRepo(rel(t)));
    if (outside.length) return { error: `explicit test(s) outside vitest_root ${root}: ${outside.join(', ')}` };
    // `covering` is the same list as PLAIN repo-relative paths, for a test-runner command line.
    return { ...out, source: 'explicit', include: tests.map((t) => escapeGlob(rel(t))), covering: [...tests],
      note: `covering tests (explicit, ${tests.length}): ${tests.join(', ')}` };
  }
  if (typeof P.matchesGlob !== 'function') {
    warnings.push('this node has no path.matchesGlob: co-located tests are not filtered by the workspace include');
  }
  const missing = [];
  const found = new Set();
  for (const f of files) {
    const hits = colocatedTests(repo, f).filter((t) => !outsideRepo(rel(t)) && matchesOwnInclude(own, rel(t)));
    if (!hits.length) missing.push(f);
    for (const t of hits) found.add(t);
  }
  if (!missing.length) {
    let covering = [...found].sort();
    // A barrel file can list half a workspace; a stated cap keeps the dry run finite, and the chosen
    // list is printed, so a truncated set is visible rather than silent.
    if (covering.length > MAX_COVERING_TESTS) {
      warnings.push(`covering tests capped at ${MAX_COVERING_TESTS} (${covering.length} found): ` +
        `${covering.slice(MAX_COVERING_TESTS).join(', ')} not selected — narrow the scope or pass --test-file`);
      covering = covering.slice(0, MAX_COVERING_TESTS);
    }
    return { ...out, source: 'colocated', include: covering.map((t) => escapeGlob(rel(t))), covering,
      note: `covering tests (${covering.length}): ${covering.join(', ')}` };
  }
  warnings.push(`covering_tests=workspace-include: no co-located test inside vitest_root ${root} for ${missing.join(', ')}`);
  const printed = own.kind === 'list' && own.globs.length ? own.globs : own.kind === 'default' ? [VITEST_DEFAULT_INCLUDE] : null;
  return { ...out, source: 'workspace-include', include: null, printed, missing, covering: null };
}

const group = (items, keyOf) => {
  const m = new Map();
  for (const it of items) { const k = keyOf(it); m.set(k, [...(m.get(k) || []), it]); }
  return [...m].map(([key, members]) => ({ key, files: members }));
};

// A co-located file the workspace's own include would never collect (a helper in __tests__, a
// Playwright *.spec.ts) must not be handed to Vitest: it fails the initial run with "No test suite
// found". Without path.matchesGlob every candidate is kept; a glob that throws matches nothing.
function matchesOwnInclude(own, relTest) {
  // An unreadable include falls back to Vitest's default: a bare `__tests__/foo.ts` helper is then not
  // a test, and the scope honestly drops to workspace-include instead.
  const all = own.kind === 'list' ? own.globs : [VITEST_DEFAULT_INCLUDE];
  const globs = all.filter((g) => !g.startsWith('!'));
  const excluded = [...all.filter((g) => g.startsWith('!')).map((g) => g.slice(1)), ...(own.exclude || [])];
  if (typeof P.matchesGlob !== 'function') return true;
  const hit = (g) => { try { return P.matchesGlob(relTest, g); } catch { return false; } };
  return globs.some(hit) && !excluded.some(hit);
}

// The Vitest config Stryker runs, written at the repo root. Every path is RELATIVE to this file's own
// location: Stryker copies the repo into a sandbox and runs there, and an absolute path would import
// the unmutated originals (every mutant "survives"). Spread, never vite's mergeConfig: mergeConfig
// concatenates arrays, which would ADD the covering tests to the workspace include, not replace it.
// `tests` (plain paths relative to `root`, NOT to the repo: the caller re-bases them) is the
// relocation-safe form — the generated config resolves them against its own location plus `root`, then
// against the root the BASE config declares at load. `include` (globs relative to `root`) stays for
// the caller that has no plain paths (workspace-include). Passing repo-relative paths here resolves
// them under the root twice (apps/runner/apps/runner/src/...).
function renderVitestConfig({ config, root, include, tests }) {
  const imp = config && config !== 'none' ? `import base from ${JSON.stringify(`./${config}`)};\n` : 'const base = {};\n';
  return '// Generated by zuvo scripts/stryker-scoped-config.sh for ONE scoped Stryker run - do not commit.\n' +
    imp +
    "import path from 'node:path';\n" +
    "import { fileURLToPath } from 'node:url';\n" +
    "const here = path.resolve(fileURLToPath(new URL('.', import.meta.url)));\n" +
    `const scopeDir = path.resolve(here, ${JSON.stringify(root)});\n` +
    `const baseDir = ${config && config !== 'none' ? `path.dirname(path.resolve(here, ${JSON.stringify(config)}))` : 'here'};\n` +
    `const tests = ${JSON.stringify(tests || [])};\n` +
    `const include = ${JSON.stringify(include)};\n` +
    "const esc = (p) => p.replace(/[*?[\\]{}()!+@|\\\\]/g, '\\\\$&');\n" +
    'export default async (env) => {\n' +
    "  const b = (typeof base === 'function' ? await base(env) : await base) ?? {};\n" +
    // Destructured away, not set to undefined: Vitest 4 rejects a present `test.workspace` key at all.
    '  const { projects, workspace, ...narrow } = b.test ?? {};\n' +
    // A base that roots itself KEEPS that root: its setupFiles/include/globals are written against it,
    // and a relative root is relative to the BASE file, not to this generated one. Overriding it (the
    // first version always did) resolved apps/runner's `setupFiles: ['./test-setup.ts']` against
    // apps/runner instead of its own test.root src/ — the initial run died on a missing module.
    "  const declared = typeof narrow.root === 'string' ? narrow.root : typeof narrow.dir === 'string' ? narrow.dir : null;\n" +
    '  const baseRoot = declared ? path.resolve(baseDir, declared) : scopeDir;\n' +
    // A test the base's own root cannot reach is a scoper bug, not something to paper over: an
    // absolute include would make Stryker's sandbox collect the UNMUTATED original (every mutant
    // survives), so the config refuses to load and the run fails instead.
    "  const rel = (p) => { const a = path.resolve(scopeDir, p); const r = path.relative(baseRoot, a);\n" +
    // `..` alone or a `..<sep>` prefix is an escape; a file called `..specs/x.test.ts` is not.
    "    if (!r || r === '..' || r.startsWith('..' + path.sep) || path.isAbsolute(r)) throw new Error('zuvo: covering test ' + p + ' is outside the base config test.root ' + baseRoot);\n" +
    '    return r; };\n' +
    '  const narrowed = tests.length ? tests.map(rel).map(esc) : include;\n' +
    // Narrowing clears exclude (the include lists exact files) and any projects/workspace a base
    // brought in at runtime that the static check could not see: those would run every project.
    '  return { ...b, root: baseRoot, test: narrowed ? { ...narrow, root: baseRoot, dir: baseRoot, include: narrowed, exclude: [] } : { ...narrow, root: baseRoot } };\n' +
    '};\n';
}

// ── the vitest-runner's per-test filter ────────────────────────────────────────────────────────
// Stryker's vitest-runner narrows a mutant's run to its covering tests by building a testNamePattern
// from the test names `collectTestName` joins with its own separator; Vitest evaluates that pattern
// against a full name built by `createTaskName` with ITS separator. Equal → per-test filtering works.
// Different → every test is skipped, each mutant reports "Ran 0.00 tests per mutant" and is marked
// SURVIVED (2026-10-20: vitest 5.0.5 joins with " > ", @stryker-mutator/vitest-runner 10.0.0 with
// " ": 168 survivors on a scope whose control mutant a hand-applied edit killed).
function packageRoot(spec, repo) {
  let entry;
  try { entry = require.resolve(spec, { paths: [repo] }); } catch { return null; }
  let dir = path.dirname(entry);
  for (;;) {
    try {
      if (JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).name === spec) return dir;
    } catch { /* no package.json here: keep walking up */ }
    const up = path.dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

const isJs = (name) => /\.(?:js|mjs|cjs)$/.test(name) && !/\.d\.[cm]?[jt]s$/.test(name);

// Sorted: readdir order is filesystem-dependent, and the scan below must name the same file — and so
// the same separator — on every machine and for every run.
function firstMatch(dir, re, depth = 0) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)); } catch { return null; }
  for (const e of entries) {
    if (!e.isFile() || !isJs(e.name)) continue;
    const m = re.exec(fs.readFileSync(path.join(dir, e.name), 'utf8'));
    if (m) return m;
  }
  if (depth >= 3) return null;
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const m = firstMatch(path.join(dir, e.name), re, depth + 1);
    if (m) return m;
  }
  return null;
}

const readKnownOrScan = (root, rels, re) => {
  for (const r of rels) {
    try { const m = re.exec(fs.readFileSync(path.join(root, r), 'utf8')); if (m) return m; } catch { /* absent: scan */ }
  }
  return firstMatch(root, re);
};

// Do the installed vitest and vitest-runner agree on how a test's full name is built?
// {ok:true} · {ok:false, unknown:false, reason} a MEASURED mismatch · {ok:false, unknown:true, reason}
// when it cannot be checked (nothing installed) — the caller keeps the plugin and relies on the
// zero-tests guard rather than guessing.
function vitestRunnerVerdict(repo) {
  const vRoot = packageRoot('vitest', repo);
  const rRoot = packageRoot('@stryker-mutator/vitest-runner', repo);
  const missing = !vRoot ? 'vitest' : !rRoot ? '@stryker-mutator/vitest-runner' : null;
  if (missing) return { ok: false, unknown: true, reason: `cannot resolve ${missing} from the repo` };
  const v = readKnownOrScan(vRoot, ['dist/task-utils.js', 'dist/task-utils.mjs'],
    /function createTaskName\([^)]*separator\s*=\s*(['"`])([^'"`]*)\1/);
  // The window is generous (a minified or bundled build can put the join far from the signature) but
  // still bound to collectTestName: an unrelated `.join(' ')` elsewhere in the bundle must not decide it.
  const r = readKnownOrScan(rRoot, ['dist/src/test-helpers.js', 'dist/test-helpers.js', 'dist/src/stryker-setup.js'],
    /function collectTestName\([\s\S]{0,4000}?return\s[\w$.]+\.join\((['"`])([^'"`]*)\1\)/);
  if (!v) return { ok: false, unknown: true, reason: 'cannot read the suite-name separator from the installed vitest' };
  if (!r) return { ok: false, unknown: true, reason: 'cannot read the suite-name separator from the installed @stryker-mutator/vitest-runner' };
  const version = (root) => { try { return JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version; } catch { return '?'; } };
  if (v[2] === r[2]) {
    return { ok: true, reason: `vitest ${version(vRoot)} and @stryker-mutator/vitest-runner ${version(rRoot)} both join suite names with ${JSON.stringify(v[2])}` };
  }
  return { ok: false, unknown: false,
    reason: `vitest ${version(vRoot)} builds a test's full name with ${JSON.stringify(v[2])} but @stryker-mutator/vitest-runner ` +
      `${version(rRoot)} builds its per-test filter with ${JSON.stringify(r[2])}: that filter matches no test, so every mutant ` +
      'runs 0 tests and is reported SURVIVED' };
}

module.exports = {
  CONFIG_NAMES, VITEST_DEFAULT_INCLUDE, escapeGlob, findNearestConfig, hasProjects, projectsForm, parseTestInclude,
  colocatedTests, importingTests, workspaceDir, resolveVitest, renderVitestConfig, vitestRunnerVerdict,
};
