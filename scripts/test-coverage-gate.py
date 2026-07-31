#!/usr/bin/env python3
"""test-coverage-gate.py — executable inventory/coverage gate for zuvo:write-tests.

The write-tests skill freezes a production-surface inventory to
zuvo/contracts/<basename>.coverage.json BEFORE any test is written, then maps
test evidence into it. This script is the independent check that the agent
cannot rationalize past:

  extract  — enumerate the production file's public entry points from its OWN
             syntax tree (TypeScript Compiler API via node, Python ast, PHP
             token_get_all). The extraction NEVER comes from the manifest, so
             the same stage can't both generate and approve the inventory.
  validate — compare manifest against a fresh extraction and against the test
             files on disk: every extracted symbol present, every owned row
             FULL (or explicitly excused with a note), every piece of evidence
             an existing test-file:line inside a real test, no duplicate or
             empty evidence, production hash unchanged, Q7/Q11 == 1.

Exit codes:
  0  PASS            (all checks green, AST-grade extraction)
  1  FAIL            (at least one gate violation — printed line by line)
  2  usage / input error (bad args, unreadable manifest, unsupported language)
  3  DEGRADED_PASS   (all checks green BUT extraction fell back to text
                      heuristics — the caller must record BLOCKED_DEGRADED,
                      never a full PASS)

Manifest schema: shared/includes/coverage-manifest-schema.md (zuvo-coverage-manifest/v1).
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SCHEMA_ID = "zuvo-coverage-manifest/v1"

TS_EXTS = {".ts", ".tsx", ".mts", ".cts"}
JS_EXTS = {".js", ".jsx", ".mjs", ".cjs"}
PY_EXTS = {".py"}
PHP_EXTS = {".php"}

RESOLVED_COVERAGE = {"FULL", "N/A", "PARTIAL-by-constraint", "UNREACHABLE"}
UNCOVERED_COVERAGE = {"NONE", "PARTIAL", "STRUCTURAL_ONLY"}
ALL_COVERAGE = RESOLVED_COVERAGE | UNCOVERED_COVERAGE

# Test-region start patterns per stack (a test file with none of these has no
# tests, so no line in it can serve as behavioral evidence).
TEST_DECL_PATTERNS = [
    re.compile(r"\b(?:it|test)(?:\.\w+)*\s*[(`]"),          # JS/TS (incl. it.each`...`)
    re.compile(r"^\s*(?:async\s+)?def\s+test_", re.M),       # pytest
    re.compile(r"\bpublic\s+function\s+test\w*", re.I),      # PHPUnit/Codeception
    re.compile(r"#\[\s*Test\s*\]|@test\b", re.I),            # PHP attributes/annotations
]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_language(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in PY_EXTS:
        return "python"
    if ext in PHP_EXTS:
        return "php"
    if ext in TS_EXTS or ext in JS_EXTS:
        return "ts"
    return None


# ── Python extraction (always AST — python3 runs this script) ─────────────────

def extract_python(path):
    import ast as ast_mod

    with open(path, encoding="utf-8") as f:
        source = f.read()
    tree = ast_mod.parse(source, filename=path)
    symbols = []

    def is_public(name):
        return not name.startswith("_")

    for node in tree.body:
        if isinstance(node, (ast_mod.FunctionDef, ast_mod.AsyncFunctionDef)):
            if is_public(node.name):
                symbols.append({
                    "symbol": node.name,
                    "kind": "function",
                    "lines": "%d-%d" % (node.lineno, node.end_lineno or node.lineno),
                })
        elif isinstance(node, ast_mod.ClassDef) and is_public(node.name):
            for item in node.body:
                if isinstance(item, (ast_mod.FunctionDef, ast_mod.AsyncFunctionDef)):
                    if is_public(item.name):
                        symbols.append({
                            "symbol": "%s.%s" % (node.name, item.name),
                            "kind": "method",
                            "lines": "%d-%d" % (item.lineno, item.end_lineno or item.lineno),
                        })
    return symbols, "ast"


# ── TypeScript / JavaScript extraction (node + typescript, else degraded) ─────

NODE_EXTRACTOR = r"""
const fs = require('fs');
const tsPath = process.argv[3];
const ts = require(tsPath);
const fileName = process.argv[2];
const source = fs.readFileSync(fileName, 'utf8');
const kind = fileName.endsWith('.tsx') || fileName.endsWith('.jsx')
  ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
const sf = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, kind);

const out = [];
function lineOf(pos) { return sf.getLineAndCharacterOfPosition(pos).line + 1; }
function lines(node) {
  return lineOf(node.getStart(sf)) + '-' + lineOf(node.getEnd());
}
function hasModifier(node, k) {
  return (ts.canHaveModifiers(node) ? ts.getModifiers(node) || [] : [])
    .some(m => m.kind === k);
}
function isExported(node) {
  return hasModifier(node, ts.SyntaxKind.ExportKeyword);
}
function publicName(name) {
  return name && !name.startsWith('#') && !name.startsWith('_');
}

function classMembers(cls, clsName) {
  for (const m of cls.members) {
    const isMethod = ts.isMethodDeclaration(m) || ts.isGetAccessor(m) || ts.isSetAccessor(m);
    if (!isMethod) {
      // public property holding an arrow function is also callable surface
      if (ts.isPropertyDeclaration(m) && m.initializer &&
          (ts.isArrowFunction(m.initializer) || ts.isFunctionExpression(m.initializer))) {
        // fall through with property treated as method-like
      } else { continue; }
    }
    if (hasModifier(m, ts.SyntaxKind.PrivateKeyword)) continue;
    if (hasModifier(m, ts.SyntaxKind.ProtectedKeyword)) continue;
    if (!m.name || !ts.isIdentifier(m.name)) continue;
    const n = m.name.text;
    if (!publicName(n)) continue;
    out.push({ symbol: clsName + '.' + n, kind: 'method', lines: lines(m) });
  }
}

ts.forEachChild(sf, node => {
  if (ts.isFunctionDeclaration(node) && node.name && isExported(node)) {
    if (publicName(node.name.text))
      out.push({ symbol: node.name.text, kind: 'function', lines: lines(node) });
  } else if (ts.isClassDeclaration(node) && node.name) {
    // Exported classes AND default-exported classes; non-exported classes are
    // not public surface.
    if (isExported(node) || hasModifier(node, ts.SyntaxKind.DefaultKeyword)) {
      classMembers(node, node.name.text);
    }
  } else if (ts.isVariableStatement(node) && isExported(node)) {
    for (const d of node.declarationList.declarations) {
      if (!ts.isIdentifier(d.name)) continue;
      const n = d.name.text;
      if (!publicName(n)) continue;
      if (d.initializer && (ts.isArrowFunction(d.initializer) || ts.isFunctionExpression(d.initializer))) {
        out.push({ symbol: n, kind: 'function', lines: lines(d) });
      }
    }
  } else if (ts.isExportAssignment(node) && !node.isExportEquals) {
    const e = node.expression;
    if (ts.isArrowFunction(e) || ts.isFunctionExpression(e)) {
      out.push({ symbol: 'default', kind: 'function', lines: lines(node) });
    }
  }
});

process.stdout.write(JSON.stringify(out));
"""


def find_typescript_module(start_dir):
    """Locate a CLASSIC TypeScript compiler API (lib/typescript.js, TS <= 5.x).

    TypeScript 7 (the Go compiler) no longer ships this file — its JS API is
    unstable and Project-based, so it is deliberately not used here. Search
    order: explicit override, walk-up direct install, walk-up pnpm store
    (transitive TS5 deps survive a TS7 upgrade there), global npm root.
    """
    import glob as glob_mod

    override = os.environ.get("ZUVO_TSC_PATH")
    if override and os.path.isfile(override):
        return override
    d = os.path.abspath(start_dir)
    while True:
        candidate = os.path.join(d, "node_modules", "typescript", "lib", "typescript.js")
        if os.path.isfile(candidate):
            return candidate
        pnpm_hits = glob_mod.glob(os.path.join(
            d, "node_modules", ".pnpm", "typescript@[0-5]*",
            "node_modules", "typescript", "lib", "typescript.js"))
        if pnpm_hits:
            return sorted(pnpm_hits)[-1]
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    npm_bin = shutil.which("npm")
    if npm_bin:
        try:
            proc = subprocess.run([npm_bin, "root", "-g"], capture_output=True,
                                  text=True, timeout=10)
            if proc.returncode == 0:
                candidate = os.path.join(proc.stdout.strip(), "typescript",
                                         "lib", "typescript.js")
                if os.path.isfile(candidate):
                    return candidate
        except (OSError, subprocess.TimeoutExpired):
            pass
    return None


def find_babel_parser(start_dir):
    """Locate @babel/parser (secondary AST path — parses TS syntax natively)."""
    d = os.path.abspath(start_dir)
    while True:
        candidate = os.path.join(d, "node_modules", "@babel", "parser")
        if os.path.isdir(candidate):
            return candidate
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


BABEL_EXTRACTOR = r"""
const fs = require('fs');
const parserPath = process.argv[3];
const parser = require(parserPath);
const fileName = process.argv[2];
const source = fs.readFileSync(fileName, 'utf8');
const isJsx = fileName.endsWith('.tsx') || fileName.endsWith('.jsx');
const ast = parser.parse(source, {
  sourceType: 'module',
  plugins: ['typescript', 'decorators-legacy'].concat(isJsx ? ['jsx'] : []),
  errorRecovery: true,
});

const out = [];
const lines = n => n.loc.start.line + '-' + n.loc.end.line;
const publicName = n => n && !n.startsWith('#') && !n.startsWith('_');

function classMembers(cls, clsName) {
  for (const m of cls.body.body) {
    const isFnProp = m.type === 'ClassProperty' && m.value &&
      (m.value.type === 'ArrowFunctionExpression' || m.value.type === 'FunctionExpression');
    if (m.type !== 'ClassMethod' && !isFnProp) continue;
    if (m.accessibility === 'private' || m.accessibility === 'protected') continue;
    if (m.kind === 'constructor') continue;
    if (!m.key || m.key.type !== 'Identifier') continue;
    if (!publicName(m.key.name)) continue;
    out.push({ symbol: clsName + '.' + m.key.name, kind: 'method', lines: lines(m) });
  }
}

for (const node of ast.program.body) {
  let decl = null, isDefault = false;
  if (node.type === 'ExportNamedDeclaration' && node.declaration) decl = node.declaration;
  else if (node.type === 'ExportDefaultDeclaration') { decl = node.declaration; isDefault = true; }
  else continue;

  if (decl.type === 'FunctionDeclaration') {
    const name = decl.id ? decl.id.name : 'default';
    if (publicName(name)) out.push({ symbol: name, kind: 'function', lines: lines(decl) });
  } else if (decl.type === 'ClassDeclaration') {
    if (decl.id) classMembers(decl, decl.id.name);
  } else if (decl.type === 'VariableDeclaration') {
    for (const d of decl.declarations) {
      if (d.id.type !== 'Identifier' || !publicName(d.id.name)) continue;
      if (d.init && (d.init.type === 'ArrowFunctionExpression' || d.init.type === 'FunctionExpression')) {
        out.push({ symbol: d.id.name, kind: 'function', lines: lines(d) });
      }
    }
  } else if (isDefault && (decl.type === 'ArrowFunctionExpression' || decl.type === 'FunctionExpression')) {
    out.push({ symbol: 'default', kind: 'function', lines: lines(node) });
  }
}

process.stdout.write(JSON.stringify(out));
"""


# Textual fallback: recognizably weaker on purpose — its use forces exit 3.
TS_FALLBACK_FN = re.compile(
    r"^export\s+(?:default\s+)?(?:async\s+)?function\s+([A-Za-z$][\w$]*)", re.M)
TS_FALLBACK_CONST = re.compile(
    r"^export\s+const\s+([A-Za-z$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s*)?\(", re.M)
TS_FALLBACK_CLASS = re.compile(
    r"^export\s+(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z$][\w$]*)", re.M)
TS_FALLBACK_METHOD = re.compile(
    r"^\s{2,6}(?:public\s+)?(?:static\s+)?(?:async\s+)?(?:\*\s*)?"
    r"([A-Za-z$][\w$]*)\s*(?:<[^>\n]*>)?\s*\(", re.M)
TS_METHOD_STOPWORDS = {
    "constructor", "if", "for", "while", "switch", "catch", "return", "new",
    "function", "super", "await", "typeof", "get", "set", "private", "protected",
}


def _run_node_extractor(node_bin, script, path, module_path):
    with tempfile.NamedTemporaryFile(
            "w", suffix=".js", delete=False, encoding="utf-8") as tf:
        tf.write(script)
        extractor = tf.name
    try:
        proc = subprocess.run(
            [node_bin, extractor, os.path.abspath(path), module_path],
            capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(extractor)
    if proc.returncode == 0 and proc.stdout.strip():
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            pass
    sys.stderr.write("extract: node extractor failed (%s)\n%s\n"
                     % (os.path.basename(module_path), proc.stderr[-500:]))
    return None


def extract_ts(path):
    node_bin = shutil.which("node")
    start_dir = os.path.dirname(os.path.abspath(path))
    if node_bin:
        ts_module = find_typescript_module(start_dir)
        if ts_module:
            symbols = _run_node_extractor(node_bin, NODE_EXTRACTOR, path, ts_module)
            if symbols is not None:
                return symbols, "ast"
        babel = find_babel_parser(start_dir)
        if babel:
            symbols = _run_node_extractor(node_bin, BABEL_EXTRACTOR, path, babel)
            if symbols is not None:
                return symbols, "ast"
        if not ts_module and not babel:
            sys.stderr.write(
                "extract: no classic typescript (<=5.x lib/typescript.js) and no "
                "@babel/parser reachable from %s — TS7's Go compiler has no stable "
                "JS API; set ZUVO_TSC_PATH to any TS5 install to restore AST-grade "
                "extraction\n" % start_dir)

    # Degraded textual heuristic
    with open(path, encoding="utf-8") as f:
        source = f.read()
    lines_list = source.splitlines()
    symbols = []
    for m in TS_FALLBACK_FN.finditer(source):
        ln = source.count("\n", 0, m.start()) + 1
        symbols.append({"symbol": m.group(1), "kind": "function", "lines": str(ln)})
    for m in TS_FALLBACK_CONST.finditer(source):
        ln = source.count("\n", 0, m.start()) + 1
        symbols.append({"symbol": m.group(1), "kind": "function", "lines": str(ln)})
    for cm in TS_FALLBACK_CLASS.finditer(source):
        cls = cm.group(1)
        cls_line = source.count("\n", 0, cm.start()) + 1
        # scan until dedented closing brace at column 0
        end_line = len(lines_list)
        for i in range(cls_line, len(lines_list)):
            if lines_list[i].startswith("}"):
                end_line = i + 1
                break
        body = "\n".join(lines_list[cls_line:end_line])
        for mm in TS_FALLBACK_METHOD.finditer(body):
            name = mm.group(1)
            if name in TS_METHOD_STOPWORDS or name.startswith("_"):
                continue
            raw_line = body[:mm.start()]
            ln = cls_line + raw_line.count("\n") + 1
            # skip lines explicitly marked private/protected
            decl = lines_list[ln - 1]
            if re.search(r"\b(?:private|protected)\b", decl):
                continue
            symbols.append({"symbol": "%s.%s" % (cls, name), "kind": "method",
                            "lines": str(ln)})
    return symbols, "degraded-text"


# ── PHP extraction (php token_get_all, else degraded) ─────────────────────────

PHP_EXTRACTOR = r"""
$file = $argv[1];
$tokens = token_get_all(file_get_contents($file));
$out = [];
$class = null; $classDepth = 0; $depth = 0;
$visibility = 'public';
for ($i = 0; $i < count($tokens); $i++) {
  $t = $tokens[$i];
  if (is_string($t)) {
    if ($t === '{') $depth++;
    if ($t === '}') { $depth--; if ($class !== null && $depth < $classDepth) { $class = null; } }
    continue;
  }
  [$id, $text, $line] = $t;
  if ($id === T_CLASS || $id === T_TRAIT) {
    for ($j = $i + 1; $j < count($tokens); $j++) {
      if (is_array($tokens[$j]) && $tokens[$j][0] === T_STRING) { $class = $tokens[$j][1]; $classDepth = $depth + 1; break; }
      if (is_string($tokens[$j]) && $tokens[$j] === '{') break;
    }
  }
  if ($id === T_PRIVATE || $id === T_PROTECTED) { $visibility = 'nonpublic'; }
  if ($id === T_PUBLIC) { $visibility = 'public'; }
  if ($id === T_FUNCTION) {
    for ($j = $i + 1; $j < count($tokens); $j++) {
      if (is_array($tokens[$j]) && $tokens[$j][0] === T_STRING) {
        $name = $tokens[$j][1];
        if ($visibility === 'public' && $name[0] !== '_') {
          $sym = $class !== null ? "$class.$name" : $name;
          $out[] = ['symbol' => $sym, 'kind' => $class !== null ? 'method' : 'function', 'lines' => (string)$line];
        }
        break;
      }
      if (is_string($tokens[$j]) && $tokens[$j] === '(') break; // closure
    }
    $visibility = 'public';
  }
}
echo json_encode($out);
"""

PHP_FALLBACK_METHOD = re.compile(
    r"^\s*(?:final\s+)?(?:public\s+)?(?:static\s+)?function\s+([A-Za-z]\w*)", re.M)


def extract_php(path):
    php_bin = shutil.which("php")
    if php_bin:
        proc = subprocess.run(
            [php_bin, "-r", PHP_EXTRACTOR, os.path.abspath(path)],
            capture_output=True, text=True, timeout=60)
        if proc.returncode == 0 and proc.stdout.strip():
            try:
                return json.loads(proc.stdout), "ast"
            except json.JSONDecodeError:
                pass
        sys.stderr.write("extract: php extraction failed, falling back to text\n")

    with open(path, encoding="utf-8") as f:
        source = f.read()
    symbols = []
    for m in PHP_FALLBACK_METHOD.finditer(source):
        decl_line = source[:m.start()].count("\n")
        decl = source.splitlines()[decl_line]
        if re.search(r"\b(?:private|protected)\b", decl):
            continue
        symbols.append({"symbol": m.group(1), "kind": "function",
                        "lines": str(decl_line + 1)})
    return symbols, "degraded-text"


def extract(path):
    lang = detect_language(path)
    if lang is None:
        raise SystemExit2("unsupported production-file language: %s" % path)
    if lang == "python":
        return extract_python(path)
    if lang == "php":
        return extract_php(path)
    return extract_ts(path)


class SystemExit2(Exception):
    """Usage/input error — mapped to exit 2 in main()."""


# ── Normalized (formatting-insensitive) hashing ───────────────────────────────
#
# Guarantee direction matters: an UNCHANGED normhash is proof the edit was
# non-semantic (comments/whitespace/line-wrap/trailing-comma only), so a prior
# blind-audit CLEAN may survive it. A CHANGED normhash may still be cosmetic
# (e.g. quote-style churn) — treat it as semantic and re-audit. Never the other
# way around.

def _normalize_c_family(source, line_comment_hash=False):
    """Strip comments, collapse whitespace, drop trailing commas — string-aware."""
    out = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if c in "'\"`":
            quote = c
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == quote:
                    j += 1
                    break
                j += 1
            out.append(source[i:j])
            i = j
        elif c == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                i += 1
        elif c == "/" and i + 1 < n and source[i + 1] == "*":
            end = source.find("*/", i + 2)
            i = n if end == -1 else end + 2
        elif line_comment_hash and c == "#":
            while i < n and source[i] != "\n":
                i += 1
        elif c.isspace():
            out.append(" ")
            while i < n and source[i].isspace():
                i += 1
        else:
            out.append(c)
            i += 1
    collapsed = "".join(out)
    # spaces are only semantic between two identifier characters
    ident = r"[A-Za-z0-9_$]"
    collapsed = re.sub(r"(?<!%s) | (?!%s)" % (ident, ident), "", collapsed)
    # prettier trailing-comma churn: `,` immediately before a closer is cosmetic
    collapsed = re.sub(r",(?=[)\]}])", "", collapsed)
    return collapsed


def _normalize_python(source):
    """Python: whitespace is semantic — only strip comments/trailing space/blank lines."""
    lines = []
    for line in source.splitlines():
        # naive-safe comment strip: only when '#' is not inside a string on that line
        stripped = ""
        in_str = None
        i = 0
        while i < len(line):
            ch = line[i]
            if in_str:
                stripped += ch
                if ch == "\\":
                    if i + 1 < len(line):
                        stripped += line[i + 1]
                    i += 2
                    continue
                if ch == in_str:
                    in_str = None
            elif ch in "'\"":
                in_str = ch
                stripped += ch
            elif ch == "#":
                break
            else:
                stripped += ch
            i += 1
        stripped = stripped.rstrip()
        if stripped:
            lines.append(stripped)
    return "\n".join(lines)


def normalized_hash(path):
    with open(path, encoding="utf-8") as f:
        source = f.read()
    lang = detect_language(path)
    if lang == "python":
        normalized = _normalize_python(source)
    elif lang == "php":
        normalized = _normalize_c_family(source, line_comment_hash=True)
    else:
        normalized = _normalize_c_family(source)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


# ── Test-name evidence resolution ─────────────────────────────────────────────
#
# `path::<test name>` evidence survives formatters (names are stable, line
# numbers are not). The name must match exactly one test declaration.

TEST_NAME_PATTERNS = [
    # it('name' / test("name" / it.each(...)`name` — capture the quoted first arg
    re.compile(r"\b(?:it|test)(?:\.\w+(?:\([^)]*\))?)*\s*\(\s*(['\"`])(?P<name>(?:\\.|(?!\1).)*)\1"),
    re.compile(r"^\s*(?:async\s+)?def\s+(?P<name>test_\w+)", re.M),
    re.compile(r"\bpublic\s+function\s+(?P<name>test\w+)", re.I),
]


def find_test_by_name(test_source, name):
    """Return (line, count) for test declarations whose name == `name`."""
    hits = []
    for pat in TEST_NAME_PATTERNS:
        for m in pat.finditer(test_source):
            if m.group("name") == name:
                hits.append(test_source.count("\n", 0, m.start()) + 1)
    return (hits[0] if hits else None), len(hits)


def enclosing_test_name(test_source, line):
    """Name of the nearest test declaration at or before `line` (1-indexed)."""
    best_line, best_name = None, None
    for pat in TEST_NAME_PATTERNS:
        for m in pat.finditer(test_source):
            decl_line = test_source.count("\n", 0, m.start()) + 1
            if decl_line <= line and (best_line is None or decl_line > best_line):
                best_line, best_name = decl_line, m.group("name")
    return best_name


# ── Validation ────────────────────────────────────────────────────────────────

EVIDENCE_RE = re.compile(r"^(?P<path>.+?):(?P<start>\d+)(?:-(?P<end>\d+))?$")
EVIDENCE_NAME_RE = re.compile(r"^(?P<path>.+?)::(?P<name>.+)$")


def load_manifest(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise SystemExit2("manifest unreadable: %s (%s)" % (path, e))
    if not isinstance(data, dict) or data.get("schema") != SCHEMA_ID:
        raise SystemExit2("manifest schema must be %r" % SCHEMA_ID)
    for key in ("production_file", "production_sha256", "symbols"):
        if key not in data:
            raise SystemExit2("manifest missing required key: %s" % key)
    if not isinstance(data["symbols"], list):
        raise SystemExit2("manifest .symbols must be an array")
    return data


def resolve_path(p, repo_root, manifest_dir):
    if os.path.isabs(p):
        return p
    for base in (repo_root, manifest_dir, os.getcwd()):
        if base:
            candidate = os.path.join(base, p)
            if os.path.isfile(candidate):
                return candidate
    return os.path.join(repo_root or os.getcwd(), p)


def first_test_decl_line(test_source):
    """1-indexed line of the first test declaration, or None."""
    best = None
    for pat in TEST_DECL_PATTERNS:
        m = pat.search(test_source)
        if m:
            line = test_source.count("\n", 0, m.start()) + 1
            if best is None or line < best:
                best = line
    return best


def validate(manifest_path, phase, repo_root):
    errors = []
    warnings = []
    manifest = load_manifest(manifest_path)
    manifest_dir = os.path.dirname(os.path.abspath(manifest_path))

    prod = resolve_path(manifest["production_file"], repo_root, manifest_dir)
    if not os.path.isfile(prod):
        raise SystemExit2("production file not found: %s" % prod)

    # 1. Freshness: production content must be exactly what was inventoried.
    current_sha = sha256_file(prod)
    if current_sha != manifest["production_sha256"]:
        errors.append(
            "STALE INVENTORY: production sha256 mismatch "
            "(manifest=%s current=%s) — production changed after freeze; "
            "rebuild the inventory" % (manifest["production_sha256"][:12], current_sha[:12]))

    # 2. Independent extraction vs manifest symbol set.
    extracted, mode = extract(prod)
    extracted_names = {s["symbol"] for s in extracted}
    manifest_names = set()
    for sym in manifest["symbols"]:
        if not isinstance(sym, dict) or "symbol" not in sym:
            errors.append("manifest symbol entry missing 'symbol' field: %r" % (sym,))
            continue
        if sym["symbol"] in manifest_names:
            errors.append("duplicate manifest symbol: %s" % sym["symbol"])
        manifest_names.add(sym["symbol"])

    missing = sorted(extracted_names - manifest_names)
    for name in missing:
        errors.append("MISSING SYMBOL: %s is a public entry point in production "
                      "but has no manifest row" % name)
    extra = sorted(manifest_names - extracted_names)
    for name in extra:
        warnings.append("manifest symbol %r not found by extractor "
                        "(indirect/dynamic surface — verify manually)" % name)

    # 3. Per-symbol structural checks.
    uncovered_rows = 0
    total_owned_rows = 0
    full_entry_points = 0
    owned_symbols = 0
    seen_evidence = {}

    for sym in manifest["symbols"]:
        if not isinstance(sym, dict) or "symbol" not in sym:
            continue
        name = sym["symbol"]
        for field in ("kind", "visibility", "production_lines", "ownership"):
            if not sym.get(field):
                errors.append("symbol %s: missing field %r" % (name, field))
        rows = sym.get("rows")
        if not isinstance(rows, list) or not rows:
            errors.append("symbol %s: has no inventory rows (need >=1 per "
                          "entry point: branches, error paths, side effects)" % name)
            rows = []
        if sym.get("ownership") == "owned":
            owned_symbols += 1

        symbol_has_full = False
        for row in rows:
            if not isinstance(row, dict):
                errors.append("symbol %s: row is not an object" % name)
                continue
            coverage = row.get("coverage", "NONE" if phase == "final" else "")
            rid = row.get("id", "?")

            if phase == "inventory":
                # Inventory freeze: rows must exist and describe the surface;
                # coverage must NOT already claim FULL (nothing is written yet).
                if coverage == "FULL":
                    errors.append("symbol %s row %s: coverage=FULL at inventory "
                                  "phase — inventory is frozen BEFORE tests exist" % (name, rid))
                if not row.get("description"):
                    errors.append("symbol %s row %s: missing description" % (name, rid))
                continue

            # phase == final
            if sym.get("ownership") != "owned":
                continue
            total_owned_rows += 1
            if coverage not in ALL_COVERAGE:
                errors.append("symbol %s row %s: invalid coverage %r" % (name, rid, coverage))
                uncovered_rows += 1
                continue
            if coverage in UNCOVERED_COVERAGE:
                uncovered_rows += 1
                errors.append("UNCOVERED OWNED ROW: %s row %s coverage=%s"
                              % (name, rid, coverage))
                continue
            if coverage in ("N/A", "PARTIAL-by-constraint", "UNREACHABLE"):
                if not row.get("note"):
                    errors.append("symbol %s row %s: coverage=%s requires a "
                                  "non-empty justification note" % (name, rid, coverage))
                continue

            # coverage == FULL → evidence must be real
            symbol_has_full = True
            evidence = row.get("evidence", "")
            if not evidence or not isinstance(evidence, str):
                errors.append("symbol %s row %s: FULL with empty evidence" % (name, rid))
                continue

            # Preferred durable form: 'test-file::exact test name' (survives
            # formatters — names are stable, line numbers are not).
            mn = EVIDENCE_NAME_RE.match(evidence.strip())
            if mn:
                ev_path = resolve_path(mn.group("path"), repo_root, manifest_dir)
                key = "%s::%s" % (os.path.normpath(mn.group("path")), mn.group("name"))
                if key in seen_evidence:
                    errors.append("DUPLICATE EVIDENCE: %s cited by both %s and %s "
                                  "— each owned row needs its own assertion"
                                  % (key, seen_evidence[key], "%s/%s" % (name, rid)))
                else:
                    seen_evidence[key] = "%s/%s" % (name, rid)
                if not os.path.isfile(ev_path):
                    errors.append("symbol %s row %s: evidence file does not exist: %s"
                                  % (name, rid, mn.group("path")))
                    continue
                with open(ev_path, encoding="utf-8") as f:
                    test_source = f.read()
                _line, count = find_test_by_name(test_source, mn.group("name"))
                if count == 0:
                    errors.append("symbol %s row %s: no test named %r in %s"
                                  % (name, rid, mn.group("name"), mn.group("path")))
                elif count > 1:
                    errors.append("symbol %s row %s: test name %r is ambiguous "
                                  "(%d declarations) in %s — rename or fall back "
                                  "to file:line" % (name, rid, mn.group("name"),
                                                    count, mn.group("path")))
                continue

            m = EVIDENCE_RE.match(evidence.strip())
            if not m:
                errors.append("symbol %s row %s: evidence %r is not "
                              "'test-file:line', 'test-file:start-end', or "
                              "'test-file::test name'"
                              % (name, rid, evidence))
                continue
            ev_path = resolve_path(m.group("path"), repo_root, manifest_dir)
            ev_line = int(m.group("start"))
            key = "%s:%s" % (os.path.normpath(m.group("path")), m.group("start"))
            if key in seen_evidence:
                errors.append("DUPLICATE EVIDENCE: %s cited by both %s and %s "
                              "— each owned row needs its own assertion"
                              % (key, seen_evidence[key], "%s/%s" % (name, rid)))
            else:
                seen_evidence[key] = "%s/%s" % (name, rid)
            if not os.path.isfile(ev_path):
                errors.append("symbol %s row %s: evidence file does not exist: %s"
                              % (name, rid, m.group("path")))
                continue
            with open(ev_path, encoding="utf-8") as f:
                test_source = f.read()
            n_lines = test_source.count("\n") + 1
            if ev_line < 1 or ev_line > n_lines:
                errors.append("symbol %s row %s: evidence line %d outside file "
                              "(%d lines): %s" % (name, rid, ev_line, n_lines, m.group("path")))
                continue
            first_decl = first_test_decl_line(test_source)
            if first_decl is None:
                errors.append("symbol %s row %s: evidence file contains no test "
                              "declarations: %s" % (name, rid, m.group("path")))
            elif ev_line < first_decl:
                errors.append("symbol %s row %s: evidence line %d precedes the "
                              "first test declaration (line %d) — points at "
                              "imports/setup, not a test" % (name, rid, ev_line, first_decl))

        if phase == "final" and sym.get("ownership") == "owned":
            if symbol_has_full:
                full_entry_points += 1
            else:
                has_excused = any(
                    isinstance(r, dict) and r.get("coverage") in
                    ("N/A", "PARTIAL-by-constraint", "UNREACHABLE") and r.get("note")
                    for r in rows)
                if not has_excused:
                    errors.append("ENTRY POINT WITHOUT FULL ROW: %s has no FULL "
                                  "behavioral row and no excused rows" % name)

    # 4. Quality gates (final only).
    if phase == "final":
        gates = manifest.get("quality_gates") or {}
        for gate in ("Q7", "Q11"):
            if gates.get(gate) != 1:
                errors.append("QUALITY GATE: %s must be 1, got %r" % (gate, gates.get(gate)))
        test_files = manifest.get("test_files") or []
        if not test_files:
            errors.append("manifest .test_files is empty at final phase")
        for tf_rel in test_files:
            if not os.path.isfile(resolve_path(tf_rel, repo_root, manifest_dir)):
                errors.append("declared test file does not exist: %s" % tf_rel)

    # ── Report ────────────────────────────────────────────────────────────────
    print("COVERAGE GATE (executable) — phase: %s" % phase)
    print("manifest:   %s" % manifest_path)
    print("production: %s" % manifest["production_file"])
    print("extraction: %s (%d public symbols)" % (mode, len(extracted_names)))
    if phase == "final":
        print("Public entry points: %d/%d FULL" % (full_entry_points, owned_symbols))
        print("Owned branch/error rows: %d/%d resolved"
              % (total_owned_rows - uncovered_rows, total_owned_rows))
        print("Uncovered owned rows: %d" % uncovered_rows)
    print("missing symbols: %s" % (", ".join(missing) if missing else "none"))
    for w in warnings:
        print("WARN: %s" % w)
    for e in errors:
        print("FAIL: %s" % e)

    if errors:
        print("RESULT: FAIL (%d violations)" % len(errors))
        return 1
    if mode != "ast":
        print("RESULT: DEGRADED_PASS (textual extraction — record "
              "BLOCKED_DEGRADED, never a full PASS)")
        return 3
    print("RESULT: PASS")
    return 0


# ── Refresh: rewrite line-based evidence to durable test-name evidence ────────

def refresh(manifest_path, repo_root):
    manifest = load_manifest(manifest_path)
    manifest_dir = os.path.dirname(os.path.abspath(manifest_path))
    converted, skipped = 0, 0
    for sym in manifest["symbols"]:
        for row in sym.get("rows") or []:
            if not isinstance(row, dict):
                continue
            evidence = (row.get("evidence") or "").strip()
            m = EVIDENCE_RE.match(evidence)
            if not m or EVIDENCE_NAME_RE.match(evidence):
                continue
            ev_path = resolve_path(m.group("path"), repo_root, manifest_dir)
            if not os.path.isfile(ev_path):
                skipped += 1
                print("SKIP %s/%s: file missing: %s"
                      % (sym.get("symbol"), row.get("id"), m.group("path")))
                continue
            with open(ev_path, encoding="utf-8") as f:
                test_source = f.read()
            tname = enclosing_test_name(test_source, int(m.group("start")))
            if not tname:
                skipped += 1
                print("SKIP %s/%s: no enclosing test at %s"
                      % (sym.get("symbol"), row.get("id"), evidence))
                continue
            _line, count = find_test_by_name(test_source, tname)
            if count != 1:
                skipped += 1
                print("SKIP %s/%s: name %r ambiguous (%d) — keeping line form"
                      % (sym.get("symbol"), row.get("id"), tname, count))
                continue
            row["evidence"] = "%s::%s" % (m.group("path"), tname)
            converted += 1
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print("REFRESH: %d evidence rows converted to test-name form, %d skipped"
          % (converted, skipped))
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────

def main(argv):
    parser = argparse.ArgumentParser(
        prog="test-coverage-gate.py",
        description="Executable inventory/coverage gate for zuvo:write-tests.")
    sub = parser.add_subparsers(dest="command")

    p_extract = sub.add_parser("extract", help="enumerate public entry points")
    p_extract.add_argument("--production", required=True)

    p_validate = sub.add_parser("validate", help="validate a coverage manifest")
    p_validate.add_argument("--manifest", required=True)
    p_validate.add_argument("--phase", choices=["inventory", "final"], default="final")
    p_validate.add_argument("--repo-root", default=None)

    p_norm = sub.add_parser(
        "normhash",
        help="formatting-insensitive sha256 (unchanged hash proves a "
             "non-semantic edit; used by the blind-audit freshness guard)")
    p_norm.add_argument("--file", required=True)

    p_refresh = sub.add_parser(
        "refresh",
        help="rewrite line-based evidence to durable test-name form "
             "(path::test name) so formatters stop invalidating manifests")
    p_refresh.add_argument("--manifest", required=True)
    p_refresh.add_argument("--repo-root", default=None)

    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 2

    try:
        if args.command == "extract":
            if not os.path.isfile(args.production):
                raise SystemExit2("production file not found: %s" % args.production)
            symbols, mode = extract(args.production)
            print(json.dumps({
                "language": detect_language(args.production),
                "mode": mode,
                "symbols": symbols,
            }, indent=2))
            return 0 if mode == "ast" else 3
        if args.command == "normhash":
            if not os.path.isfile(args.file):
                raise SystemExit2("file not found: %s" % args.file)
            print(normalized_hash(args.file))
            return 0
        if args.command == "refresh":
            return refresh(args.manifest, args.repo_root)
        return validate(args.manifest, args.phase, args.repo_root)
    except SystemExit2 as e:
        sys.stderr.write("ERROR: %s\n" % e)
        return 2
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: extractor subprocess timed out\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
