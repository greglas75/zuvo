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
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize

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

NODE_BOUNDARIES = r"""
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
function text(n) { return n.getText(sf).replace(/\s+/g, ' ').slice(0, 90); }

const REL = {
  [ts.SyntaxKind.LessThanToken]: '<',
  [ts.SyntaxKind.LessThanEqualsToken]: '<=',
  [ts.SyntaxKind.GreaterThanToken]: '>',
  [ts.SyntaxKind.GreaterThanEqualsToken]: '>=',
};
const EQ = {
  [ts.SyntaxKind.EqualsEqualsEqualsToken]: '===',
  [ts.SyntaxKind.ExclamationEqualsEqualsToken]: '!==',
  [ts.SyntaxKind.EqualsEqualsToken]: '==',
  [ts.SyntaxKind.ExclamationEqualsToken]: '!=',
};
const LOGIC = {
  [ts.SyntaxKind.BarBarToken]: '||',
  [ts.SyntaxKind.AmpersandAmpersandToken]: '&&',
  [ts.SyntaxKind.QuestionQuestionToken]: '??',
};
const ARITH = {
  [ts.SyntaxKind.PlusToken]: '+',
  [ts.SyntaxKind.MinusToken]: '-',
  [ts.SyntaxKind.AsteriskToken]: '*',
  [ts.SyntaxKind.SlashToken]: '/',
  [ts.SyntaxKind.PercentToken]: '%',
};

function walk(node) {
  if (ts.isBinaryExpression(node)) {
    const op = node.operatorToken.kind;
    if (REL[op]) {
      out.push({ kind: 'comparison', op: REL[op], line: lineOf(node.getStart(sf)),
                 expr: text(node),
                 left: text(node.left), right: text(node.right) });
    } else if (EQ[op]) {
      out.push({ kind: 'equality', op: EQ[op], line: lineOf(node.getStart(sf)),
                 expr: text(node),
                 left: text(node.left), right: text(node.right) });
    } else if (LOGIC[op]) {
      out.push({ kind: 'logic', op: LOGIC[op], line: lineOf(node.getStart(sf)),
                 expr: text(node) });
    } else if (ARITH[op]) {
      // String concatenation is not a boundary -- see the babel walker for why.
      const strSide = (x) => x && (ts.isStringLiteral(x) ||
        ts.isTemplateExpression(x) || ts.isNoSubstitutionTemplateLiteral(x));
      if (!strSide(node.left) && !strSide(node.right)) {
        out.push({ kind: 'arithmetic', op: ARITH[op], line: lineOf(node.getStart(sf)),
                   expr: text(node) });
      }
    }
  } else if (ts.isThrowStatement(node)) {
    out.push({ kind: 'throw', line: lineOf(node.getStart(sf)), expr: text(node.expression) });
  } else if (node.questionDotToken) {
    // `a?.b` -- a mutation runner deletes the `?.`, and only a case where the left side is
    // actually null/undefined can tell the difference.
    out.push({ kind: 'optional', line: lineOf(node.getStart(sf)), expr: text(node) });
  } else if (ts.isElementAccessExpression(node) &&
             ts.isNumericLiteral(node.argumentExpression)) {
    out.push({ kind: 'index', line: lineOf(node.getStart(sf)),
               expr: text(node), idx: node.argumentExpression.text });
  }
  ts.forEachChild(node, walk);
}
walk(sf);
process.stdout.write(JSON.stringify(out));
"""



BABEL_BOUNDARIES = r"""
const fs = require('fs');
const parser = require(process.argv[3]);
const fileName = process.argv[2];
const source = fs.readFileSync(fileName, 'utf8');
const isJsx = fileName.endsWith('.tsx') || fileName.endsWith('.jsx');
const ast = parser.parse(source, {
  sourceType: 'module',
  plugins: ['typescript', 'decorators-legacy'].concat(isJsx ? ['jsx'] : []),
  errorRecovery: true,
});

const out = [];
const REL = new Set(['<', '<=', '>', '>=']);
const EQ  = new Set(['===', '!==', '==', '!=']);
const ARITH = new Set(['+', '-', '*', '/', '%']);
const LOGIC = new Set(['||', '&&', '??']);

function txt(n) {
  if (!n || n.start == null) return '';
  return source.slice(n.start, n.end).replace(/\s+/g, ' ').slice(0, 90);
}

function walk(n) {
  if (!n || typeof n.type !== 'string') return;
  const line = n.loc ? n.loc.start.line : 0;
  if (n.type === 'BinaryExpression') {
    if (REL.has(n.operator)) {
      out.push({ kind: 'comparison', op: n.operator, line, expr: txt(n),
                 left: txt(n.left), right: txt(n.right) });
    } else if (EQ.has(n.operator)) {
      out.push({ kind: 'equality', op: n.operator, line, expr: txt(n),
                 left: txt(n.left), right: txt(n.right) });
    } else if (ARITH.has(n.operator)) {
      // String concatenation is not a boundary: swap the operator and the program throws on any
      // input, so the mutant dies on the first test that runs and the row is pure noise.
      const strSide = (x) => x && (x.type === 'StringLiteral' || x.type === 'TemplateLiteral');
      if (!strSide(n.left) && !strSide(n.right)) {
        out.push({ kind: 'arithmetic', op: n.operator, line, expr: txt(n) });
      }
    }
  } else if (n.type === 'LogicalExpression' && LOGIC.has(n.operator)) {
    out.push({ kind: 'logic', op: n.operator, line, expr: txt(n) });
  } else if (n.type === 'ThrowStatement') {
    out.push({ kind: 'throw', line, expr: txt(n.argument) });
  } else if (n.type === 'OptionalMemberExpression' || n.type === 'OptionalCallExpression') {
    out.push({ kind: 'optional', line, expr: txt(n) });
  } else if (n.type === 'MemberExpression' && n.computed &&
             n.property && n.property.type === 'NumericLiteral') {
    out.push({ kind: 'index', line, expr: txt(n), idx: String(n.property.value) });
  }
  for (const k of Object.keys(n)) {
    if (k === 'loc' || k === 'leadingComments' || k === 'trailingComments') continue;
    const v = n[k];
    if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === 'object' && typeof v.type === 'string') walk(v);
  }
}
walk(ast.program);
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
    """Python: whitespace is semantic — only strip comments/trailing space/blank lines.

    Tokenizer-based ON PURPOSE. The previous hand-rolled scanner tracked string state
    with a single quote char RESET ON EVERY LINE, so it had no idea a triple-quoted
    string was open: any line inside a docstring/SQL blob was truncated at the first
    `#`, and editing the text after that `#` left the hash UNCHANGED. That inverts this
    module's entire guarantee (an unchanged normhash is proof the edit was cosmetic —
    see the comment above), letting a stale blind-audit CLEAN survive a semantic edit.
    `tokenize` gets multi-line strings, f-strings, escapes and line continuations right
    by construction. (4 of 5 adversarial providers converged on this independently.)
    """
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(source).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        # Unparseable file (partial edit, py2 syntax, template): fall back to the
        # STRICTEST possible answer — hash the raw source. A false "changed" costs one
        # re-audit; a false "unchanged" ships a stale CLEAN, which is the failure this
        # function exists to prevent.
        return source

    out = []
    for tok in toks:
        if tok.type in (tokenize.COMMENT, tokenize.NL):
            continue  # cosmetic by definition
        if tok.type == tokenize.NEWLINE:
            out.append("\n")
            continue
        if tok.type in (tokenize.INDENT, tokenize.DEDENT):
            # Indentation IS semantic in Python: keep it as an explicit marker rather
            # than raw spaces, so a tab/space reindent does not read as a logic change.
            out.append("\x01" if tok.type == tokenize.INDENT else "\x02")
            continue
        if tok.type == tokenize.ENDMARKER:
            continue
        out.append(tok.string)
        out.append(" ")  # one separator; collapsed below
    normalized = "".join(out)
    # collapse the separators we just inserted, but never across a newline marker
    normalized = re.sub(r"[ \t]+", " ", normalized)
    normalized = re.sub(r" ?\n ?", "\n", normalized)
    return normalized.strip()


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

        # 4b. Proof that the suite was actually MEASURED, not just declared finished.
        #
        # Measured across the benchmark corpus: about one run in three never executes the
        # verification command at all. Not failing it — declining it. One transcript puts it
        # plainly: "isn't practical to run in full here, I'll follow its core spine pragmatically."
        # The suite then ships unmeasured while the run reports success, and every number computed
        # from it describes nothing.
        #
        # Two rewordings of the instruction have already failed to change this, so the check is
        # here instead: `verify-tests` writes a receipt into the manifest, and the receipt carries
        # the sha256 of each spec it measured. Hashes are what make it evidence rather than a
        # checkbox — edit a spec afterwards and the receipt goes stale, so it cannot be inherited
        # from an earlier, different suite.
        receipt = manifest.get("verification")
        if not isinstance(receipt, dict) or not receipt.get("spec_sha256"):
            errors.append(
                "UNVERIFIED: manifest is marked final but carries no verification receipt. "
                "Run `~/.zuvo/verify-tests --manifest %s` — a suite nothing measured is not a "
                "finished suite." % os.path.basename(manifest_path))
        else:
            measured = receipt.get("spec_sha256") or {}
            for tf_rel in test_files:
                tf_abs = resolve_path(tf_rel, repo_root, manifest_dir)
                if not os.path.isfile(tf_abs):
                    continue
                recorded = measured.get(tf_rel)
                if recorded is None:
                    errors.append(
                        "UNVERIFIED SPEC: %s is declared but was never measured — the receipt "
                        "covers %s" % (tf_rel, ", ".join(sorted(measured)) or "nothing"))
                elif recorded != sha256_file(tf_abs):
                    errors.append(
                        "STALE RECEIPT: %s changed after it was measured; re-run "
                        "`~/.zuvo/verify-tests` so the verdict describes the current suite"
                        % tf_rel)

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

def _line_span(sym):
    """(first, last) production lines for an extracted symbol, or None if unparseable."""
    raw = sym.get("lines") or sym.get("production_lines") or ""
    m = re.match(r"^\s*(\d+)\s*-\s*(\d+)\s*$", str(raw))
    if m:
        return int(m.group(1)), int(m.group(2))
    if str(raw).strip().isdigit():
        n = int(str(raw).strip())
        return n, n
    return None


# The same measured survival order `boundaries` reports in: across 39 suites on one file a deleted
# throw survived 34 times, a flipped comparison 27, a shifted literal index 15, a swapped boolean
# 12. A generated inventory that lists 55 equality rows before the throws buries the rows that
# actually cost points, and an agent working top-down then spends its budget on the cheap ones.
BOUNDARY_PRIORITY = {"throw": 0, "comparison": 1, "optional": 2, "index": 3,
                     "logic": 4, "arithmetic": 5, "equality": 6}

# Past this many rows on one file, the skill's own doctrine says split rather than grind. The
# generator does not enforce that — it has no way to know whether a split is possible — but it
# must not silently manufacture an inventory the skill would tell you not to work through.
SPLIT_ADVISORY_ROWS = 60

ROW_TYPE_BY_KIND = {
    "throw": "error_path",
    "comparison": "branch",
    "equality": "branch",
    "logic": "branch",
    "optional": "branch",
    "index": "branch",
    "arithmetic": "branch",
}


def scaffold(production, test_files, repo_root, out_path):
    """Emit a complete inventory manifest: every public symbol, every boundary, coverage NONE.

    Why this exists. The inventory is the entry cost of the whole protocol, and on a large file it
    is prohibitive by hand: measured on the benchmark corpus, one 304-line file with 88 branches
    was abandoned in NINE consecutive runs across three skill versions — no manifest was ever
    written, so the gate never ran and neither did anything downstream of it. The agents said why:
    running the full apparatus "isn't practical here". At ~90 hand-authored rows they were right.

    Hand-authoring was never the point, either. The rows have to agree with what the validator
    extracts, and the validator extracts them itself — so writing them by hand is transcription
    with a chance of error, and the error is what the gate then reports. Generating them from the
    same extractor makes the two agree by construction and leaves the agent the part that actually
    needs judgement: which test proves which row.

    Boundaries are attached to the symbol whose line span contains them. One that falls outside
    every span (module-level code, a nested closure the extractor does not surface as public) is
    kept on the nearest enclosing symbol rather than dropped -- an obligation nobody owns is an
    obligation nobody covers.
    """
    # realpath on BOTH sides before relpath: on macOS /var is a symlink to /private/var, so
    # mixing a resolved path with an unresolved one produces a `../../../..` climb out of the tree
    # that only fails later, inside the validator, as "production file not found".
    prod_abs = os.path.realpath(production)
    if not os.path.isfile(prod_abs):
        raise SystemExit2("production file not found: %s" % production)
    symbols, mode = extract(prod_abs)
    if not symbols:
        raise SystemExit2("no public symbols extracted from %s — nothing to inventory" % production)

    spans = []
    for sym in symbols:
        span = _line_span(sym)
        spans.append((span[0], span[1], sym["symbol"]) if span else (0, 0, sym["symbol"]))

    def owner(line):
        best, best_size = None, None
        for lo, hi, name in spans:
            if lo <= line <= hi:
                size = hi - lo
                if best_size is None or size < best_size:   # innermost wins
                    best, best_size = name, size
        if best:
            return best
        # Nearest enclosing by start line, so module-level work still lands somewhere owned.
        prior = [(lo, name) for lo, _hi, name in spans if lo <= line]
        return max(prior)[1] if prior else spans[0][2]

    obligations = boundaries(prod_abs) or []
    by_symbol = {}
    for ob in obligations:
        by_symbol.setdefault(owner(ob.get("line") or 0), []).append(ob)

    rows_out = []
    for sym in symbols:
        name = sym["symbol"]
        rows = [{"id": "E1", "type": "entry",
                 "description": "TODO: what %s does on its ordinary input" % name,
                 "coverage": "NONE", "evidence": ""}]
        owned = sorted(by_symbol.get(name, []),
                       key=lambda o: (BOUNDARY_PRIORITY.get(o.get("kind"), 9), o.get("line") or 0))
        for i, ob in enumerate(owned, 1):
            rows.append({
                "id": "B%d" % i,
                "type": ROW_TYPE_BY_KIND.get(ob.get("kind"), "branch"),
                "description": "L%s %s: %s" % (ob.get("line"), ob.get("kind"), ob.get("expr", "")),
                "coverage": "NONE",
                "evidence": "",
            })
        rows_out.append({
            "symbol": name,
            "kind": sym.get("kind") or "function",
            "visibility": "public",
            "production_lines": sym.get("lines") or sym.get("production_lines") or "",
            "ownership": "owned",
            "rows": rows,
        })

    manifest_dir = os.path.dirname(os.path.abspath(out_path)) or "."
    manifest = {
        "schema": SCHEMA_ID,
        "production_file": os.path.relpath(prod_abs, os.path.realpath(repo_root)),
        "production_sha256": sha256_file(prod_abs),
        "stack": detect_language(prod_abs) or "ts",
        "test_files": list(test_files or []),
        "quality_gates": {"Q7": 0, "Q11": 0},
        "status": "inventory",
        "symbols": rows_out,
    }
    os.makedirs(manifest_dir, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)

    total_rows = sum(len(s["rows"]) for s in rows_out)
    print("SCAFFOLD: %s" % out_path)
    print("  extraction: %s (%d public symbol%s)" % (mode, len(symbols), "" if len(symbols) == 1 else "s"))
    print("  rows:       %d (%d entry + %d boundary), all coverage=NONE" % (
        total_rows, len(symbols), total_rows - len(symbols)))
    print("  order:      highest-risk kinds first (throw, comparison, optional, index, ...), "
          "so top-down work spends the budget where mutants actually survive")
    if not obligations:
        print("  NOTE: no boundary obligations available — branch rows must be added by hand")
    if total_rows > SPLIT_ADVISORY_ROWS:
        print("  NOTE: %d rows on one file is past the %d-row point where this skill's own rule "
              "says SPLIT rather than grind. Generating them is cheap; covering them is not. "
              "Check the split rule before working straight down this list."
              % (total_rows, SPLIT_ADVISORY_ROWS))
    print("  Fill `coverage` and `evidence` per row as tests land, set Q7/Q11, then flip status "
          "to final and run ~/.zuvo/verify-tests.")
    return 0


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


# ── Boundary obligations ──────────────────────────────────────────────────────
#
# Measured on the benchmark rig 2026-08-21 across 39 suites for one file: the mutants that
# separate an 88% suite from a 91% one are not exotic. They are `value < 0` surviving a change
# to `value <= 0` (27 of 39 suites), a literal 0 bumped to 1 (27 of 39), a `throw` deleted
# outright (34 of 39), and `normalized[0]` shifted to `normalized[1]` (15 of 39). Every one is
# a boundary the tests never sat exactly on.
#
# The guidance already existed -- `test-edge-cases.md` says "exact threshold N, N-1, N+1" -- but
# it lives in a row keyed on code TYPE, so a bare `value < 0` inside a pure function never
# triggers it. Classification decides whether the rule applies, and classification is a
# judgement made before the comparisons are known.
#
# This derives the obligations from the source instead. Every relational operator implies two
# adjacent inputs; every throw implies a test that fails when the throw is deleted; every
# literal index implies a case where that position differs from its neighbour.

PY_CMP = {
    "Lt": "<", "LtE": "<=", "Gt": ">", "GtE": ">=",
    "Eq": "==", "NotEq": "!=", "Is": "is", "IsNot": "is not",
}


def boundaries_python(path):
    import ast as ast_mod
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    try:
        tree = ast_mod.parse(src)
    except SyntaxError:
        return None
    out = []
    for node in ast_mod.walk(tree):
        if isinstance(node, ast_mod.Compare) and node.ops:
            op = PY_CMP.get(type(node.ops[0]).__name__)
            if op:
                out.append({"kind": "comparison" if op in ("<", "<=", ">", ">=") else "equality",
                            "op": op, "line": node.lineno,
                            "expr": ast_mod.unparse(node)[:90],
                            "left": ast_mod.unparse(node.left)[:40],
                            "right": ast_mod.unparse(node.comparators[0])[:40]})
        elif (isinstance(node, ast_mod.BinOp)
              and type(node.op).__name__ in ("Add", "Sub", "Mult", "Div", "Mod", "FloorDiv")
              and not any(isinstance(side, ast_mod.Constant) and isinstance(side.value, str)
                          for side in (node.left, node.right))):
            sym = {"Add": "+", "Sub": "-", "Mult": "*", "Div": "/",
                   "Mod": "%", "FloorDiv": "//"}[type(node.op).__name__]
            out.append({"kind": "arithmetic", "op": sym, "line": node.lineno,
                        "expr": ast_mod.unparse(node)[:90]})
        elif isinstance(node, ast_mod.BoolOp):
            # Parity with the TS walker: `a or b` and `a and b` are the operators a mutation
            # runner swaps, and a test where both operands agree passes under either one.
            out.append({"kind": "logic",
                        "op": "or" if isinstance(node.op, ast_mod.Or) else "and",
                        "line": node.lineno, "expr": ast_mod.unparse(node)[:90]})
        elif isinstance(node, ast_mod.Raise):
            out.append({"kind": "throw", "line": node.lineno,
                        "expr": ast_mod.unparse(node.exc)[:90] if node.exc else "re-raise"})
        elif (isinstance(node, ast_mod.Subscript)
              and isinstance(node.slice, ast_mod.Constant)
              and isinstance(node.slice.value, int)):
            out.append({"kind": "index", "line": node.lineno,
                        "expr": ast_mod.unparse(node)[:90], "idx": str(node.slice.value)})
    return out


def boundaries_ts(path):
    """TypeScript compiler API first, @babel/parser second — the same chain `extract` uses.

    The fallback is not theoretical: TypeScript 7 ships a Go compiler with no classic
    `lib/typescript.js`, so on a repo that has upgraded, the first bridge finds nothing and the
    only thing standing between this command and a DEGRADED verdict is babel.
    """
    node_bin = shutil.which("node")
    if not node_bin:
        return None
    start_dir = os.path.dirname(os.path.abspath(path))
    ts_module = find_typescript_module(start_dir)
    if ts_module:
        found = _run_node_extractor(node_bin, NODE_BOUNDARIES, path, ts_module)
        if found is not None:
            return found
    babel = find_babel_parser(start_dir)
    if babel:
        return _run_node_extractor(node_bin, BABEL_BOUNDARIES, path, babel)
    return None


def boundaries(path):
    lang = detect_language(path)
    if lang == "python":
        return boundaries_python(path)
    if lang in ("ts", "js"):
        return boundaries_ts(path)
    return None


def report_boundaries(path, show_all=False, as_json=False):
    items = boundaries(path)
    if as_json:
        # Machine-readable form for verify-tests, which maps a surviving mutant's LINE back to
        # the obligation it failed. A raw mutant id says a test is missing; the obligation says
        # which case to write.
        json.dump({"schema": "zuvo-boundaries/v1",
                   "production_file": path,
                   "available": items is not None,
                   "obligations": items or []},
                  sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0 if items is not None else 3
    # relpath against CWD can produce a longer, uglier string than the input; show
    # whichever is shorter so the header stays readable from any directory.
    shown = min(path, os.path.relpath(path), key=len)
    print("BOUNDARY OBLIGATIONS - %s" % shown)
    if items is None:
        print("  unavailable: no parser for this language "
              "(TS/JS needs node + a classic typescript module; Python is built in)")
        print("  Treat as BLOCKED_DEGRADED for boundary evidence -- not as 'no boundaries'.")
        return 3
    if not items:
        print("  none found - no comparisons, throws or literal indexes in this file")
        return 0

    # One row per distinct (kind, line, expr): the same comparison reported twice is noise.
    seen, rows = set(), []
    for it in items:
        key = (it["kind"], it["line"], it.get("expr"))
        if key in seen:
            continue
        seen.add(key)
        rows.append(it)
    rows.sort(key=lambda r: (r["line"], r["kind"]))

    counts = {}
    for r in rows:
        counts[r["kind"]] = counts.get(r["kind"], 0) + 1
    print("  %s" % "  ".join("%s: %d" % (k, counts[k]) for k in sorted(counts)))
    print()
    # The advice is per KIND, so it is stated once. Repeating it under each of 25 throws turns
    # a work list into a wall of text, and a wall of text is skimmed.
    print("WHAT EACH KIND REQUIRES")
    if "comparison" in counts:
        print("  COMPARISON  an input where the two sides are EQUAL - that case alone separates")
        print("              < from <=, > from >= - plus one clearly on each side.")
    if "equality" in counts:
        print("  EQUALITY    one case that satisfies it and one that misses by the smallest")
        print("              possible margin: adjacent value, off-by-one length, null vs undefined.")
    if "logic" in counts:
        print("  LOGIC       one case where the LEFT side alone decides the result and one where")
        print("              the RIGHT side alone does. Only those separate || from &&; a test")
        print("              where both operands agree passes under either operator.")
    if "throw" in counts:
        print("  THROW       a test that FAILS when this throw is DELETED: assert the message or")
        print("              type, not merely that something threw, and reach THIS throw's path.")
    if "arithmetic" in counts:
        print("  ARITHMETIC  operands where swapping the operator CHANGES the result. `x + 0`,")
        print("              `x * 1` and equal operands pass under the mutated operator too, so")
        print("              they prove nothing about which one is written.")
    if "optional" in counts:
        print("  OPTIONAL    a case where the left side really IS null/undefined. Delete the `?.`")
        print("              and nothing changes unless a test actually takes that path.")
    if "index" in counts:
        print("  INDEX       a case where that position differs from its neighbour, so reading the")
        print("              wrong element changes the result.")
    print()
    # Ordered by MEASURED survival frequency, not alphabetically: across 39 suites on CASE-01 a
    # deleted throw survived 34 times, a flipped comparison 27, a shifted literal index 15, a
    # swapped boolean 12. Listing 55 equality rows before the throws buries the ones that
    # actually cost points.
    PRIORITY = {"throw": 0, "comparison": 1, "optional": 2, "index": 3,
                "logic": 4, "arithmetic": 5, "equality": 6}
    rows.sort(key=lambda r: (PRIORITY.get(r["kind"], 9), r["line"]))
    cap = 10 ** 6 if show_all else 60
    print("OBLIGATIONS (highest-risk kinds first)")
    for r in rows[:cap]:
        print("  L%-4d %-11s %s" % (r["line"], r["kind"].upper(), r["expr"]))
    if len(rows) > cap:
        # Never silently truncate: a list that stops without saying so reads as complete.
        rest = {}
        for r in rows[cap:]:
            rest[r["kind"]] = rest.get(r["kind"], 0) + 1
        print("  ... %d more, all lower-risk kinds (%s). Re-run with --all to see them; a file"
              % (len(rows) - cap, ", ".join("%s %d" % (k, v) for k, v in sorted(rest.items()))))
        print("      needing this many rows is also a split candidate — see the Step 1.6 rule.")
    print()
    print("Each obligation is an inventory row. A row whose evidence does not distinguish the")
    print("boundary is not covered, however green the suite is.")
    return 0

def main(argv):
    parser = argparse.ArgumentParser(
        prog="test-coverage-gate.py",
        description="Executable inventory/coverage gate for zuvo:write-tests.")
    sub = parser.add_subparsers(dest="command")

    p_extract = sub.add_parser("extract", help="enumerate public entry points")
    p_extract.add_argument("--production", required=True)

    p_bounds = sub.add_parser(
        "boundaries",
        help="list the boundary obligations a suite must sit exactly on "
             "(comparisons, throws, literal indexes)")
    p_bounds.add_argument("--production", required=True)
    p_bounds.add_argument("--all", action="store_true",
                          help="list every obligation instead of the highest-risk 60")
    p_bounds.add_argument("--json", action="store_true",
                          help="machine-readable form (used by ~/.zuvo/verify-tests to name the "
                               "obligation a surviving mutant failed)")

    p_validate = sub.add_parser("validate", help="validate a coverage manifest")
    p_validate.add_argument("--manifest", required=True)
    p_validate.add_argument("--phase", choices=["inventory", "final"], default="final")
    p_validate.add_argument("--repo-root", default=None)

    p_norm = sub.add_parser(
        "normhash",
        help="formatting-insensitive sha256 (unchanged hash proves a "
             "non-semantic edit; used by the blind-audit freshness guard)")
    p_norm.add_argument("--file", required=True)

    p_scaffold = sub.add_parser(
        "scaffold",
        help="generate the inventory manifest (every public symbol, every boundary, coverage NONE)")
    p_scaffold.add_argument("--production", required=True)
    p_scaffold.add_argument("--out", required=True, help="path to write the manifest to")
    p_scaffold.add_argument("--test-files", nargs="*", default=[],
                            help="planned spec paths, repo-relative")
    p_scaffold.add_argument("--repo-root", default=".")

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
        if args.command == "boundaries":
            return report_boundaries(args.production, args.all, args.json)
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
        if args.command == "scaffold":
            return scaffold(args.production, args.test_files, args.repo_root, args.out)
        return validate(args.manifest, args.phase, args.repo_root)
    except SystemExit2 as e:
        sys.stderr.write("ERROR: %s\n" % e)
        return 2
    except subprocess.TimeoutExpired:
        sys.stderr.write("ERROR: extractor subprocess timed out\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
