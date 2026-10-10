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

// True when the config fans out to several projects: `test.projects` / `test.workspace` in ANY test
// object, or a `vitest.workspace.*` file beside it. Such a config runs every project, whatever
// `include` says.
function hasProjects(repo, relConfig) {
  if (WORKSPACE_FILES.some((n) => exists(repo, P.join(P.dirname(relConfig), n)))) return true;
  return testObjects(fs.readFileSync(path.join(repo, relConfig), 'utf8')).some((k) => k.projects || k.workspace);
}

// `test: shared`, `defineConfig({ test })`: the test options live elsewhere and cannot be read here.
const opaqueTest = (src) => /(?:^|[^\w$.])(?:test\s*:\s*[^\s{]|test\s*[,}])/.test(blank(src));

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

// foo.test.*, foo.spec.* beside the source, and __tests__/foo.* (with or without .test/.spec).
function colocatedTests(repo, relFile) {
  const dir = P.dirname(relFile);
  const stem = escapeRe(P.basename(relFile).replace(/\.[^.]+$/, ''));
  const beside = new RegExp(`^${stem}\\.(test|spec)${TEST_EXT}`);
  const nested = new RegExp(`^${stem}(\\.(test|spec))?${TEST_EXT}`);
  const list = (d) => (exists(repo, d) ? fs.readdirSync(path.join(repo, d)) : []);
  return [
    ...list(dir).filter((n) => beside.test(n)).map((n) => P.join(dir, n)),
    ...list(P.join(dir, '__tests__')).filter((n) => nested.test(n)).map((n) => P.join(dir, '__tests__', n)),
  ].sort();
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
  if (override && hasProjects(repo, override)) {
    return { error: `--vitest-config ${override} declares test.projects/workspace: every project would run and no include can narrow it — pass a workspace config` };
  }
  if (!override) {
    const byConfig = group(files, (f) => findNearestConfig(repo, f) || 'none');
    if (byConfig.length > 1) return { groups: byConfig };
    config = byConfig[0].key === 'none' ? null : byConfig[0].key;
    if (config && hasProjects(repo, config)) {
      return { aggregator: config,
        groups: group(files, (f) => workspaceDir(repo, f)) };
    }
  }
  const root = config ? P.dirname(config) : '.';
  const rel = (f) => (root === '.' ? f : P.relative(root, f));
  const src = config ? fs.readFileSync(path.join(repo, config), 'utf8') : '';
  const own = config ? parseTestInclude(src) : { kind: 'default' };
  const ownExclude = config ? parseTestInclude(src, 'exclude') : { kind: 'default' };
  // `!pattern` (a re-include) is ignored: a re-included test may be dropped, never wrongly added.
  own.exclude = ownExclude.kind === 'list' ? ownExclude.globs.filter((g) => !g.startsWith('!')) : [];
  const warnings = [];
  if (config && ownExclude.kind === 'unknown') {
    warnings.push(`${config} test.exclude cannot be read: co-located tests are not filtered by it`);
  }
  if (config && !opaqueTest(src) && /mergeConfig|extends|\.\.\.\s*[\w$]+\s*[,}]/.test(blank(src))) {
    warnings.push(`${config} spreads or merges another config: whether it is multi-project cannot be read`);
  }
  if (config && opaqueTest(src)) {
    warnings.push(`${config} takes its test options from a variable: whether it is multi-project cannot be read`);
  }
  const setsRoot = config && testObjects(src).some((k) => k.root || k.dir);
  if (setsRoot || (config && /(?:^|[^\w$.])root\s*:/.test(blank(src)))) {
    warnings.push(`${config} sets a root/test.root/test.dir; the scoped run roots it at ${root} (and test.dir too when it narrows the include)`);
  }
  const out = { config: config || 'none', root, warnings };
  const away = files.filter((f) => outsideRepo(rel(f)));
  if (away.length) warnings.push(`scoped file(s) outside vitest_root ${root}: ${away.join(', ')} — only tests under ${root} can run`);
  if (tests.length) {
    const outside = tests.filter((t) => outsideRepo(rel(t)));
    if (outside.length) return { error: `explicit test(s) outside vitest_root ${root}: ${outside.join(', ')}` };
    return { ...out, source: 'explicit', include: tests.map((t) => escapeGlob(rel(t))) };
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
  if (!missing.length) return { ...out, source: 'colocated', include: [...found].sort().map((t) => escapeGlob(rel(t))) };
  warnings.push(`covering_tests=workspace-include: no co-located test inside vitest_root ${root} for ${missing.join(', ')}`);
  const printed = own.kind === 'list' && own.globs.length ? own.globs : own.kind === 'default' ? [VITEST_DEFAULT_INCLUDE] : null;
  return { ...out, source: 'workspace-include', include: null, printed, missing };
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
function renderVitestConfig({ config, root, include }) {
  const imp = config && config !== 'none' ? `import base from ${JSON.stringify(`./${config}`)};\n` : 'const base = {};\n';
  return '// Generated by zuvo scripts/stryker-scoped-config.sh for ONE scoped Stryker run - do not commit.\n' +
    imp +
    "import path from 'node:path';\n" +
    "import { fileURLToPath } from 'node:url';\n" +
    `const root = path.resolve(fileURLToPath(new URL('.', import.meta.url)), ${JSON.stringify(root)});\n` +
    `const include = ${JSON.stringify(include)};\n` +
    'export default async (env) => {\n' +
    "  const b = (typeof base === 'function' ? await base(env) : await base) ?? {};\n" +
    '  const t = b.test ?? {};\n' +
    // Narrowing clears exclude (the include lists exact files) and any projects/workspace a base
    // brought in at runtime that the static check could not see: those would run every project.
    '  return { ...b, root, test: include ? { ...t, root, dir: root, include, exclude: [], projects: undefined, workspace: undefined } : { ...t, root } };\n' +
    '};\n';
}

module.exports = {
  CONFIG_NAMES, VITEST_DEFAULT_INCLUDE, escapeGlob, findNearestConfig, hasProjects, parseTestInclude,
  colocatedTests, workspaceDir, resolveVitest, renderVitestConfig,
};
