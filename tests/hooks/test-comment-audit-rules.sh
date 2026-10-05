#!/usr/bin/env bash
# Contract for scripts/zuvo-home/zuvo_comment_rules.py: which authored comment lines comment-audit flags.
# D, N and L findings decide rc 1, so every boundary and pattern alternation is pinned with hand-derived values,
# and a seeded fuzz pins that evaluate() and carried_lines() never raise and keep ids content-keyed.
# Level: unit — a python subprocess calls the module's pure functions; no git, no network.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || { echo "FAIL: cannot resolve the repo root"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
HELPERS="$ROOT/scripts/zuvo-home"
fail=0
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }

# Needs no python, so it runs before the SKIP gate; without both modules the driver would only crash.
for module in zuvo_comment_scan.py zuvo_comment_rules.py; do
  if [ -f "$HELPERS/$module" ] && [ ! -x "$HELPERS/$module" ]; then
    pass "$module is a plain, non-executable module"
  else
    bad "$module is missing or executable in $HELPERS"; printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"; exit 1
  fi
done

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1

TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/driver.py" <<'PY'
import ast
import contextlib
import faulthandler
import hashlib
import io
import os
import random
import re
import sys
import time
from collections import Counter

HANG_SECONDS = 600
faulthandler.dump_traceback_later(HANG_SECONDS, exit=True)
sys.path.insert(0, sys.argv[1])
import zuvo_comment_scan as s
import zuvo_comment_rules as r

CHECKS = []
PATH = "pkg/mod.py"
REASON = "keeps the lock order"
POLY = "''''exec \"$(command -v python3 || command -v python || echo python3)\" \"$0\" \"$@\" # '''"
FUZZ_INPUTS = 150
FUZZ_LANGS = ("python", "sh", "ruby", "js", "jsx", "ts", "tsx", "go", "php")
TIGHT = {"ZUVO_COMMENT_MIN_LINES": "1", "ZUVO_COMMENT_BLOCK_MIN": "2", "ZUVO_COMMENT_MAX_DENSITY": "0.1"}
PERF_SECONDS = 5

def check(name):
    def register(fn):
        CHECKS.append((name, fn))
        return fn
    return register

def equal(got, want):
    return [] if got == want else ["got %r, want %r" % (got, want)]

def case(name, compute, want):
    CHECKS.append((name, lambda: equal(compute(), want)))

def table(rows, compute):
    return ["%r -> %r, want %r" % (given, got, want) for given, want in rows for got in [compute(given)] if got != want]

def raises(call, needle=""):
    try:
        call()
    except ValueError as exc:
        return [] if needle in str(exc) else ["message %r does not name %s" % (str(exc)[:80], needle)]
    return ["no ValueError"]

def sha8(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]

def view(src, lang="python", path=PATH, added=None, carried=()):
    rows = range(len(s.split_lines(src))) if added is None else added
    return r.FileView(path=path, lang=lang, text=src, added=frozenset(rows), carried=frozenset(carried))

def audit(src, env=None, **kw):
    return r.evaluate(view(src, **kw), r.load_thresholds(env or {}))

def hits(src, rule=None, env=None, **kw):
    return [(f.rule, f.sub, f.line) for f in audit(src, env, **kw).findings if rule in (None, f.rule)]

def ids_of(src):
    return [f.id for f in audit(src).findings]

# ---- thresholds (R5) -------------------------------------------------------------------------------------
def thresholds(env):
    return {name: (t.value, t.source) for name, t in r.load_thresholds(env).items()}

DEFAULT_TH = {"density": (0.30, "default"), "min_lines": (20, "default"), "block": (4, "default"),
              "justify_max": (2, "default")}
TH_CASES = [
    ("defaults are density 0.30, min_lines 20, block 4, justify_max 2, sourced default", {}, DEFAULT_TH),
    ("a variable equal to its default is still sourced env", {"ZUVO_COMMENT_MAX_DENSITY": "0.30"},
     dict(DEFAULT_TH, density=(0.30, "env"))),
    ("an empty variable counts as unset", {"ZUVO_COMMENT_MAX_DENSITY": "", "ZUVO_COMMENT_MIN_LINES": ""}, DEFAULT_TH),
    ("boundary values 1, 1, 2 and 0 are valid and sourced env",
     {"ZUVO_COMMENT_MAX_DENSITY": "1", "ZUVO_COMMENT_MIN_LINES": "1", "ZUVO_COMMENT_BLOCK_MIN": "2",
      "ZUVO_COMMENT_JUSTIFY_MAX": "0"},
     {"density": (1.0, "env"), "min_lines": (1, "env"), "block": (2, "env"), "justify_max": (0, "env")}),
    ("surrounding spaces around a number are accepted", {"ZUVO_COMMENT_MAX_DENSITY": " 0.25 "},
     dict(DEFAULT_TH, density=(0.25, "env"))),
    ("the ledger variable is not a threshold", {"ZUVO_COMMENT_AUDIT_LOG": "/x/ledger.log"}, DEFAULT_TH),
]
for th_name, th_env, th_want in TH_CASES:
    case("thresholds: " + th_name, lambda e=th_env: thresholds(e), th_want)
case("thresholds: integer thresholds are ints, density is a float",
     lambda: {n: type(t.value).__name__ for n, t in r.load_thresholds({"ZUVO_COMMENT_MIN_LINES": "7"}).items()},
     {"density": "float", "min_lines": "int", "block": "int", "justify_max": "int"})
case("thresholds: the thresholds line shows each value and its source",
     lambda: r.describe_thresholds(r.load_thresholds({})),
     "density=0.30(default) min_lines=20(default) block=4(default) justify_max=2(default)")
case("thresholds: env values are marked env in the thresholds line, a third decimal is kept",
     lambda: [r.describe_thresholds(r.load_thresholds(e)) for e in ({"ZUVO_COMMENT_MAX_DENSITY": "0.9",
              "ZUVO_COMMENT_BLOCK_MIN": "6"}, {"ZUVO_COMMENT_MAX_DENSITY": "0.255"})],
     ["density=0.90(env) min_lines=20(default) block=6(env) justify_max=2(default)",
      "density=0.255(env) min_lines=20(default) block=4(default) justify_max=2(default)"])
case("thresholds: env_overrides lists the variables set, in table order, and never the ledger variable",
     lambda: [r.env_overrides(r.load_thresholds(e)) for e in ({"ZUVO_COMMENT_BLOCK_MIN": "6",
              "ZUVO_COMMENT_MAX_DENSITY": "0.9"}, {"ZUVO_COMMENT_AUDIT_LOG": "/x/ledger.log"})],
     [["ZUVO_COMMENT_MAX_DENSITY", "ZUVO_COMMENT_BLOCK_MIN"], []])

INVALID = [("ZUVO_COMMENT_MAX_DENSITY", v) for v in ("nan", "inf", "0", "1.5", "abc", "-0.5", "1e-1", " ")] + [
    ("ZUVO_COMMENT_MIN_LINES", "0"), ("ZUVO_COMMENT_MIN_LINES", "2.5"), ("ZUVO_COMMENT_BLOCK_MIN", "1"),
    ("ZUVO_COMMENT_JUSTIFY_MAX", "-1"), ("ZUVO_COMMENT_MIN_LINES", "1" * 5000)]
CHECKS.append(("thresholds: %d invalid values (nan, inf, 0, 1.5, abc, MIN_LINES=0, BLOCK_MIN=1, JUSTIFY_MAX=-1, ...) "
               "raise ValueError naming the variable" % len(INVALID), lambda: table([(x, []) for x in INVALID],
                                                                                 lambda x: raises(lambda: r.load_thresholds({x[0]: x[1]}), x[0]))))

# ---- D: authored density (R2, QA M9) ---------------------------------------------------------------------
def dens(comments, code):
    return "".join(("# why %s\n" % chr(97 + i) if i < comments else "") + "v%d = %d\n" % (i, i) for i in range(code))

def density_of(src, env=None, **kw):
    res = audit(src, env, **kw)
    return res.authored_comment, res.authored_code, res.density, [f.id for f in res.findings if f.rule == "D"]

DOCS7 = "".join('def f%d():\n    """Doc %s."""\n    return %d\n' % (i, "abcdefg"[i], i) for i in range(7))
case("D: 6 comment + 14 code = 0.30 exactly is no breach, 7 + 13 = 0.35 breaches, 6 + 13 = 19 lines is below the floor",
     lambda: [density_of(dens(c, k)) for c, k in ((6, 14), (7, 13), (6, 13))],
     [(6, 14, 6 / 20, []), (7, 13, 7 / 20, ["D:pkg/mod.py"]), (6, 13, None, [])])
case("D: MIN_LINES=19 gates 6 + 13 (6/19 > 0.30)",
     lambda: density_of(dens(6, 13), {"ZUVO_COMMENT_MIN_LINES": "19"}), (6, 13, 6 / 19, ["D:pkg/mod.py"]))
case("D: MAX_DENSITY=0.35 does not breach on exactly 0.35",
     lambda: density_of(dens(7, 13), {"ZUVO_COMMENT_MAX_DENSITY": "0.35"}), (7, 13, 7 / 20, []))
case("D: the finding sits on the first AUTHORED comment line, with sub density>limit",
     lambda: hits(dens(8, 13), "D", added=set(range(1, 21))), [("D", "0.350>0.30", 3)])
case("D: mixed rows count as code and delimiter-only rows count as nothing",
     lambda: density_of("x = 1  # trailing words\n" * 20 + "#\n" * 10), (0, 20, 0.0, []))
case("D: python docstrings are comment lines", lambda: density_of(DOCS7), (7, 14, 7 / 21, ["D:pkg/mod.py"]))
case("D: carried rows and rows outside the diff are not authored; only carried rows count as carried",
     lambda: [density_of(dens(7, 13), **kw) + (audit(dens(7, 13), **kw).carried,)
              for kw in ({"carried": {0}}, {"added": set(range(1, 20))})], [(6, 13, None, [], 1), (6, 13, None, [], 0)])
case("D: whole-file density covers every line and never gates",
     lambda: [(x.authored_code, x.authored_comment, x.density, x.file_density, x.findings)
              for x in [audit(dens(2, 8), added={1})]], [(1, 0, None, 2 / 10, [])])

# ---- carried lines (R2, QA M1-M3) ------------------------------------------------------------------------
case("carried: a line removed from one file and added to another is carried (whole-diff pool)",
     lambda: r.carried_lines({"b.py": {0: "# moved note", 1: "x = 1"}}, ["# moved note", "y = 2"]), {"b.py": {0}})
case("carried: one removed copy carries one of two added copies, the first by row",
     lambda: r.carried_lines({"a.py": {9: "# twin", 3: "# twin"}}, ["# twin"]), {"a.py": {3}})
case("carried: two removed copies carry both added copies",
     lambda: r.carried_lines({"a.py": {9: "# twin", 3: "# twin"}}, ["# twin", "# twin"]), {"a.py": {3, 9}})
case("carried: re-indented and re-spaced lines are carried",
     lambda: r.carried_lines({"a.py": {0: "# keep  this", 1: "\tx = 1"}}, ["        # keep this   ", "x  =  1"]),
     {"a.py": {0, 1}})
case("carried: a changed character makes the line authored",
     lambda: r.carried_lines({"a.py": {0: "# keep this."}}, ["# keep this"]), {"a.py": set()})
case("carried: files are matched in path order whatever the input order",
     lambda: r.carried_lines({"b.py": {0: "# same"}, "a.py": {5: "# same"}}, ["# same"]), {"a.py": {5}, "b.py": set()})

# ---- N: narrative markers (R2, QA M11) -------------------------------------------------------------------
PRECISION = [
    ('see docs/specs/2026-10-02-comment-pass.md', None), ('the format is `2026-01-01` here', None),
    ('accepts "2026-01-01" or \'2026-01-02\' as input', None), ('we decided 2026 targets', None),
    ('separate 2020 rows', None), ('Jan 2026 rollout', 'N-date'), ('ships on 2026-09-01', 'N-date'),
    ('valid until 2027-03', 'N-date'), ('outage handling path', None), ('incident response path', None),
    ('outage on 2026-09-01', 'N-date'), ('outage tracked as OPS-12', 'N-incident'),
    ('incident #42 follow-up', 'N-incident'), ('incident with ops-12 in lower case', None),
    ('hotfix for the parser', 'N-incident'), ('see the post-mortem', 'N-incident'),
    ('postmortem notes', 'N-incident'), ('field run results', 'N-incident'), ('previously we used X', 'N-history'),
    ('we switched to the queue', 'N-history'), ('the flag was introduced for safety', 'N-history'),
    ('migrated from the old store', 'N-history'), ('measured: x', None), ('timeout measured in seconds', None),
    ('measured on ryzen', 'N-measured'), ('it turns out the cache is cold', 'N-measured'),
    ('kiedyś to uprościmy', None), ('wcześniej było inaczej', 'N-pl'), ('najwcześniejszy termin', None),
    ('zmierzone w tests/x.sh', None), ('zmierzone ręcznie', 'N-pl'), ('incydent na produkcji', 'N-pl'),
    ('see a1b2c3d for context', None), ('PROJ-123 tracks the follow-up', None),
]

def family(text):
    found = [f.sub for f in audit("x = 0\n# %s\ny = 1\n" % text).findings if f.rule == "N"]
    return found[0] if len(found) == 1 else (found or None)

for p_text, p_want in PRECISION:
    case("N precision: %r -> %s" % (p_text, p_want or "no finding"), lambda t=p_text: family(t), p_want)

MONTHS = ("january february march april may june july august september october november december "
          "jan feb mar apr jun jul aug sep oct nov dec").split()
FAMILIES = {
    "N-date": [m + " 2026" for m in MONTHS] + ["Dec. 2025", "Sept 2026", "2026-01", "2026-12-31", "1999-07-04", "2026-02-29"],
    "N-history": ["previously", "formerly", "originally", "used to", "until recently", "at the time", "back then",
                  "historically", "we changed", "we switched", "we moved", "we replaced", "we removed", "was changed",
                  "was replaced", "was removed", "was introduced", "changed from", "switched from", "migrated from",
                  "in the old version", "in the old code", "in the old implementation", "in the previous version",
                  "in the previous code", "in the previous implementation"],
    "N-incident": ["post-mortem", "postmortem", "hotfix", "field run", "field failure", "field report", "field data",
                   "incident OPS-1", "incidents #12", "outage AB-7", "outages #3", "incident" + " x" * 140 + " OPS-1"],
    "N-measured": ["measured on", "measured at", "measured over", "measured across", "measured by",
                   "benchmark showed", "benchmark shows", "benchmark on", "benchmarked showed", "we saw",
                   "we observed", "we measured", "turned out", "it turns out", "empirically"],
    "N-pl": ["wcześniej", "poprzednio", "incydent", "incydenty", "zmierzono", "zmierzone"],
    None: ["2026-00", "2026-13", "2026-01-32", "2126-01", "1899-05", "Mayday 2026", "incident" + " x" * 160 + " OPS-1"],
}
for fam_name, fam_phrases in FAMILIES.items():
    CHECKS.append(("N table: %d phrases -> %s" % (len(fam_phrases), fam_name or "no finding (ISO and month bounds, "
                                                "an incident anchor past the 300-char span)"),
                   lambda w=fam_name, p=fam_phrases: table([(x, w) for x in p], lambda x: family("the %s here" % x))))

N_ROWS = [
    ("x = 0\n# alpha\n# beta\n# a hotfix\ny = 1\n", [("N", "N-incident", 4)]),
    ("x = 0\n# `alpha`\n# 'beta'\n# hotfix\ny = 1\n", [("N", "N-incident", 4)]),
    ("x = 0\n# ząb żółw ćma\n# wcześniej\ny = 1\n", [("N", "N-pl", 3)]),
    ("x = 0\n# the cache used\n# to be cold\ny = 1\n", [("N", "N-history", 2)]),
    ("# previously a tool\n# second words\n# third words\n# fourth words\nx = 1\n", [("N", "N-history", 1)]),
    ("x = 0\n# previously alpha\n# shipped 2026-01-02\ny = 1\n", [("N", "N-date", 3)]),
    ("x = 1  # previously alpha\n", [("N", "N-history", 1)]),
    ('def f():\n    """Formerly a class."""\n    return 1\n', [("N", "N-history", 2)]),
    ("x = 0\n# the outage\n# tracked as OPS-7\ny = 1\n", [("N", "N-incident", 2)]),
]
CHECKS.append(("N: one finding per block, first family in table order, on its row — at the last character, after "
               "rows scrubbed empty, in multi-byte text, across a wrapped line, in the header (exempt from L only), "
               "a trailing comment, a docstring, an incident anchor on the next line", lambda: table(N_ROWS, hits)))
case("N: an authored marker line in a legacy block is flagged on its own line",
     lambda: hits("x = 0\n# plain words\n# previously alpha\ny = 1\n", added={0, 2, 3}), [("N", "N-history", 3)])
case("N: a marker on an untouched legacy line is ignored when a plain line joins its block",
     lambda: hits("x = 0\n# previously alpha\n# plain words\ny = 1\n", added={0, 2, 3}), [])
case("N: a BOM before the first comment is not part of its text or id",
     lambda: [(f.id, f.text) for f in audit("\ufeff# previously alpha\nx = 1\n").findings],
     [("N:pkg/mod.py:" + sha8("previously alpha"), "previously alpha")])
case("N: a carried narrative comment is not authored", lambda: hits("x = 0\n# previously alpha\ny = 1\n", carried={1}), [])

# ---- L: block longer than its code (R2, QA M10) ----------------------------------------------------------
L4 = "# a\n# b\n# c\n# d\n"
DOC_HEAD = 'def f(x):\n    """One.\n\n    Two.\n    Three.\n    Four.\n    """\n    a = 1\n\n    b = 2\n\n'
SIX = "x = 0\n\n# a\n# b\n# c\n# d\n# e\n# f\ny = 1\n"
ORACLES = ("Oracle", "dual-oracle")
case("L: a 4-line block over 3 lines of code is too long, over 4 lines it is fine",
     lambda: [hits("x = 0\n\n" + L4 + code, "L") for code in ("y = 1\nz = 2\nw = 3\n", "y = 1\nz = 2\nw = 3\nv = 4\n")],
     [[("L", "4>3", 3)], []])
case("L: a 3-line block is below BLOCK_MIN, and BLOCK_MIN=3 from env flags it",
     lambda: [hits("x = 0\n\n# a\n# b\n# c\n", "L", env) for env in ({}, {"ZUVO_COMMENT_BLOCK_MIN": "3"})],
     [[], [("L", "3>0", 3)]])
case("L: the id hashes the block text, the hint and text come with it",
     lambda: [(f.id, f.text, f.hint) for f in audit("x = 0\n\n" + L4 + "y = 1\n").findings],
     [("L:pkg/mod.py:" + sha8("a\nb\nc\nd"), "a", "cut to the WHY, or delete it if it restates the code")])
HEADERS = [("python", L4 + "x = 1\n"), ("sh", "#!/bin/sh\n" + L4 + "echo hi\n"),
           ("go", "package main\n\n// a\n// b\n// c\n// d\nfunc f() {}\n"),
           ("php", "<?php\n// a\n// b\n// c\n// d\n$x = 1;\n"), ("php", "\ufeff<?php\n// a\n// b\n// c\n// d\n$x = 1;\n"),
           ("python", "#!/bin/sh\n" + POLY + '\n"""a\nb\nc\nd\n"""\nimport os\n'),
           ("python", '"""a\nb\nc\nd\n"""\ny = 1\n\nz = 2\n')]
CHECKS.append(("L: the file header is exempt: first block, or after a shebang, package, <?php (BOM too), polyglot "
               "line, and a top module docstring", lambda: table([(h, []) for h in HEADERS],
                                                                  lambda h: hits(h[1], "L", lang=h[0]))))
case("L: a column-0 docstring below the header is measured against the next code run",
     lambda: hits('x = 0\n\n"""a\nb\nc\nd\n"""\ny = 1\n\nz = 2\nw = 3\nv = 4\n', "L"), [("L", "4>1", 3)])
case("L: only the first block is the header",
     lambda: hits(L4 + "x = 1\n\n# e\n# f\n# g\n# h\ny = 1\n", "L"), [("L", "4>1", 7)])
case("L: 1 or 2 of 6 word lines authored is out of scope, 3 of 6 (exactly half) is in scope",
     lambda: [hits(SIX, "L", added=a) for a in ({4}, {3, 4}, {2, 3, 4})], [[], [], [("L", "6>1", 3)]])
case("L: a block opening with Oracle: or dual-oracle is exempt",
     lambda: [hits("x();\n\n// %s: spec\n// b\n// c\n// d\nexpect(x);\n" % o, "L", lang="js") for o in ORACLES],
     [[], []])
case("L: Oracle: on a later line does not exempt the block",
     lambda: hits("x();\n\n// a\n// Oracle: spec\n// c\n// d\nexpect(x);\n", "L", lang="js"), [("L", "4>1", 3)])
case("L: an Oracle: block is still checked for narration",
     lambda: hits("x();\n\n// Oracle: previously agreed\n// b\n// c\n// d\nexpect(x);\n", lang="js"),
     [("N", "N-history", 3)])
case("L: a docstring is measured against its whole body (blank rows skipped, not counted): 4 lines fine, 3 too few",
     lambda: [hits(DOC_HEAD + tail, "L") for tail in ("    c = 3\n\n    return a + b + c\n", "    return a + b\n")],
     [[], [("L", "4>3", 2)]])
case("L: a multi-line signature counts toward the definition body",
     lambda: hits("x = 0\n\n" + L4 + "def f(\n    a,\n    b,\n):\n    return a\n", "L"), [])
case("L: one blank line after the block is skipped, two leave no described code",
     lambda: [hits("x = 0\n\n" + L4 + gap + "y = 1\nz = 2\nw = 3\nv = 4\n", "L") for gap in ("\n", "\n\n")],
     [[], [("L", "4>0", 3)]])
case("L: the described code ends at the next comment line",
     lambda: hits("x = 0\n\n" + L4 + "y = 1\nz = 2\n# e\nw = 3\nv = 4\nu = 5\nt = 6\n", "L"), [("L", "4>2", 3)])
case("L: delimiter-only rows do not count toward the block: 3 word rows fine, 4 over 3 lines too long",
     lambda: [hits("x();\n\n/**\n" + rows + " */\ny();\nz();\nw();\n", "L", lang="js")
              for rows in (" * a\n * b\n * c\n", " * a\n * b\n * c\n * d\n")], [[], [("L", "4>3", 4)]])

PRE = {"python": "x = 0", "ruby": "x = 0", "js": "x();", "go": "x := 0", "php": "<?php\n$x = 0;"}
MARK = {"python": "#", "ruby": "#", "js": "//", "go": "//", "php": "//"}
DEFS = [("python", "def f():", "    a = 1", ""), ("python", "async def f():", "    a = 1", ""),
        ("python", "class C:", "    a = 1", ""), ("python", "@decorator\n@other(arg)\ndef f():", "    a = 1", ""),
        ("python", "@dec(\n    arg,\n)\ndef f():", "    a = 1", ""),
        ("js", "function f() {", "  a();", "}"), ("js", "export default async function load() {", "  a();", "}"),
        ("js", "function* gen() {", "  a();", "}"), ("go", "func (r *T) Name() {", "\ta()", "}"),
        ("go", "func Name() {", "\ta()", "}"), ("php", "public static function f() {", "    $a = 1;", "}"),
        ("ruby", "def f", "  a = 1", "end")]
NOT_DEFS = [("go", "method := r.Method", "y := 1"), ("js", "func(x);", "y();"), ("python", "class_ = 1", "y = 1"),
            ("python", "method = x", "y = 1")]

def above(lang, code):
    return "%s\n\n%s%s\n" % (PRE[lang], "".join("%s %s\n" % (MARK[lang], w) for w in "abcd"), code)

@check("L: a block right above a definition is measured against its body, blank rows skipped (%d signatures)"
       % len(DEFS))
def definition_bodies():
    rows = []
    for lang, sig, line, close in DEFS:
        first = PRE[lang].count("\n") + 3
        for n, want in ((4, []), (3, [("L", "4>3", first)])):
            body = "\n\n".join([line] * n) + ("\n" + close if close else "")
            rows.append(((lang, sig, n), want, hits(above(lang, sig + "\n" + body), "L", lang=lang)))
    return ["%r: got %r, want %r" % (given, got, want) for given, want, got in rows if got != want]

CHECKS.append(("L: plain statements are no signature, so the next code run is measured (%d statements)"
               % len(NOT_DEFS), lambda: table([((lang, code, more), []) for lang, code, more in NOT_DEFS],
                                              lambda g: hits(above(g[0], "\n".join([g[1]] + [g[2]] * 3)), "L", lang=g[0]))))

# ---- C: quantitative claims (R2) -------------------------------------------------------------------------
CLAIM_ROWS = [(x, True) for x in ("5 ms", "5ms", "2 s", "3 sec", "1 second", "4 seconds", "2 min", "1 minute",
                                  "3 minutes", "1 h", "1 hour", "2 hours", "8 KB", "16 MB", "2 GB", "3 retries",
                                  "5 attempts", "3 times", "1.5 s", "50%", "50 %", "50%.", "within 5", "at most 3",
                                  "at least 2", "up to 10", "guarantee", "guarantees", "guaranteed")]
CLAIM_ROWS += [(x, False) for x in ("never blocks", "always sorted", "v2 s", "at most a few", "within reach", "guaranty")]

def claims(text, **kw):
    return [c.text for c in audit("x = 0\n# %s\ny = 1\n" % text, **kw).claims]

CHECKS.append(("C table: every unit, bound and guarantee form is a claim; bare always/never are not (%d rows)"
               % len(CLAIM_ROWS), lambda: table(CLAIM_ROWS, lambda x: claims("takes %s here" % x) != [])))
case("C: claims never make findings and carry the 1-based line, trailing comments included",
     lambda: [(x.findings, [(c.line, c.text) for c in x.claims])
              for x in [audit("x = 0\n# returns within 5 s\ny = 1  # retried 3 times\n")]],
     [([], [(2, "returns within 5 s"), (3, "retried 3 times")])])
case("C: a claim on an untouched line is not reported", lambda: claims("returns within 5 s", added={0, 2}), [])

# ---- finding ids (R2) ------------------------------------------------------------------------------------
case("ids: finding_id hashes the comment text, a D id is the path",
     lambda: [r.finding_id("N", "a.py", "previously alpha"), r.finding_id("L", "d/b.py", "a\nb"),
              r.finding_id("D", "a.py", "x")],
     ["N:a.py:" + sha8("previously alpha"), "L:d/b.py:" + sha8("a\nb"), "D:a.py"])
case("ids: an N id is the hash of the block's word lines",
     lambda: ids_of("x = 0\n# previously alpha\n#\n# second words\ny = 1\n"),
     ["N:pkg/mod.py:" + sha8("previously alpha\nsecond words")])

@check("ids: editing another comment or shifting the block keeps an id; editing the comment changes it")
def id_stability():
    base = "x = 0\n# previously alpha\ny = 1\n\n# formerly beta\nz = 2\n"
    a, b, c = ids_of(base), ids_of(base.replace("formerly beta", "formerly gamma")), ids_of("a = 0\nb = 0\n" + base)
    return equal(([len(x) for x in (a, b, c)], [x[0] for x in (a, b, c)], a[-1] != b[-1]),
                 ([2, 2, 2], ["N:pkg/mod.py:" + sha8("previously alpha")] * 3, True))

case("ids: identical narrative blocks get distinct ids, the first keeps the plain hash",
     lambda: [(len(f), f[0], f[0] != f[-1]) for f in [ids_of("x = 0\n# previously alpha\ny = 1\n# previously alpha\n")]],
     [(2, "N:pkg/mod.py:" + sha8("previously alpha"), True)])

# ---- justification (R6, QA M4, M5) -----------------------------------------------------------------------
JSRC = "x = 0\n# previously alpha\ny = 1\n# formerly beta\nz = 2\n# originally gamma\nw = 3\n"
ONE = "x = 0\n# previously alpha\ny = 1\n"
JIDS = ["N:%s:%s" % (PATH, sha8(t)) for t in ("previously alpha", "formerly beta", "originally gamma")]
ODD = "N:a:deadbeef=b.py:" + sha8("previously alpha")
STALE_IDS = ("N:x=y.py:0123abcd", "N:a/deadbeef=b.py:0123abcd", "D:gone.py")

def arg(ident, reason=REASON):
    return "%s=%s" % (ident, reason)

def justify(args, cap=2, path=PATH, src=JSRC):
    findings = audit(src, path=path).findings
    res = r.apply_justifications(findings, args, cap)
    return (list(res.accepted.items()), [(x.id, x.kind) for x in res.rejected], list(res.stale),
            r.is_breach(findings, res))

case("justify: the fixture's three findings carry the hand-derived ids", lambda: ids_of(JSRC), JIDS)
case("justify: the cap accepts in argument order and rejects the third as over the cap",
     lambda: justify([arg(JIDS[2]), arg(JIDS[0]), arg(JIDS[1])]),
     ([(JIDS[2], REASON), (JIDS[0], REASON)], [(JIDS[1], "over-cap")], [], True))
case("justify: a cap of 3 accepts all three and clears the breach",
     lambda: justify([arg(i) for i in JIDS], cap=3), ([(i, REASON) for i in JIDS], [], [], False))
case("justify: a 19-character reason is short, 20 is accepted",
     lambda: justify([arg(JIDS[0], REASON[:-1]), arg(JIDS[1], REASON)]),
     ([(JIDS[1], REASON)], [(JIDS[0], "short")], [], True))
case("justify: 20 spaces and a space-padded short reason are short",
     lambda: justify([arg(JIDS[0], " " * 20), arg(JIDS[1], "   short   ")]),
     ([], [(JIDS[0], "short"), (JIDS[1], "short")], [], True))
case("justify: a stale id is listed, does not use the cap and does not breach",
     lambda: justify(["N:pkg/mod.py:00000000=" + REASON, arg(JIDS[0])], cap=1, src=ONE),
     ([(JIDS[0], REASON)], [], ["N:pkg/mod.py:00000000"], False))
case("justify: JUSTIFY_MAX=0 rejects every justification",
     lambda: justify([arg(JIDS[0])], cap=r.load_thresholds({"ZUVO_COMMENT_JUSTIFY_MAX": "0"})["justify_max"].value),
     ([], [(JIDS[0], "over-cap")], [], True))
case("justify: a path containing '=' splits after the hash",
     lambda: justify(["N:dir/a=b.py:%s=reason with = sign inside" % sha8("previously alpha")], path="dir/a=b.py", src=ONE),
     ([("N:dir/a=b.py:" + sha8("previously alpha"), "reason with = sign inside")], [], [], False))
case("justify: a current id is matched whole, even with ':' and hex-like '=' segments in its path",
     lambda: justify([arg(ODD)], path="a:deadbeef=b.py", src=ONE), ([(ODD, REASON)], [], [], False))
case("justify: stale ids split after the hash (N) or on the first '=' (D)",
     lambda: [r.apply_justifications([], [a + "=" + REASON], 2).stale for a in STALE_IDS], [[a] for a in STALE_IDS])
case("justify: the longest current id wins when one id is a prefix of another",
     lambda: r.apply_justifications([r.Finding(i, "D", "", 1, "", "") for i in ("D:x", "D:x=y.py")],
                                    ["D:x=y.py=" + REASON], 2).accepted, {"D:x=y.py": REASON})
case("justify: tabs, CR, LF and '|' in a reason become spaces",
     lambda: justify([arg(JIDS[0], "line one\tline|two\r\nthree words")])[0],
     [(JIDS[0], "line one line two  three words")])
case("justify: a second justification of the same id is rejected but is no breach once the id is justified",
     lambda: justify([arg(JIDS[0]), arg(JIDS[0], "another long enough reason")], cap=3, src=ONE),
     ([(JIDS[0], REASON)], [(JIDS[0], "duplicate")], [], False))
case("justify: a short reason made up by a later valid one for the same id is no breach",
     lambda: justify([arg(JIDS[0], "too short"), arg(JIDS[0])], src=ONE),
     ([(JIDS[0], REASON)], [(JIDS[0], "short")], [], False))
case("justify: only an over-cap rejection is a breach by itself",
     lambda: [r.is_breach([], r.Justification({}, [r.Rejection(JIDS[0], kind, "x")], [])) for kind in
              (r.OVER_CAP, r.DUPLICATE, r.SHORT)], [True, False, False])
case("justify: a density finding with '=' in its path is justified by its full id",
     lambda: justify(["D:dir/x=y.py=a dense table of constants"], path="dir/x=y.py", src=dens(7, 13)),
     ([("D:dir/x=y.py", "a dense table of constants")], [], [], False))
CHECKS.append(("justify: an argument without '=' or with an empty id raises ValueError",
               lambda: raises(lambda: r.apply_justifications([], ["no-equals-sign"], 2))
               + raises(lambda: r.apply_justifications([], ["=" + REASON], 2))))
case("verdict: pass, breach, justified, and breach with one of two findings justified",
     lambda: [r.verdict([], {}), r.verdict(audit(ONE).findings, {}), r.verdict(audit(ONE).findings, {JIDS[0]: REASON}),
              r.verdict(audit(JSRC).findings[:2], {JIDS[0]: REASON})], ["pass", "breach", "justified", "breach"])

# ---- errors, constants, purity, self-audit, performance --------------------------------------------------
CHECKS.append(("evaluate: an unknown language raises ValueError",
               lambda: raises(lambda: r.evaluate(view("x", lang="cobol"), r.load_thresholds({})))))

@check("evaluate: scanner rows that disagree with the text's line count raise ValueError")
def row_mismatch():
    original = s.classify
    s.classify = lambda text, lang: (["code"], {}, set(), False)
    try:
        return raises(lambda: r.evaluate(view("x = 1\ny = 2\n"), r.load_thresholds({})))
    finally:
        s.classify = original

case("constants: narrative families and claim patterns in table order",
     lambda: [name for name, _ in r.NARRATIVE + r.CLAIM_PATTERNS],
     ["N-date", "N-history", "N-incident", "N-measured", "N-pl", "number-unit", "percent", "bound", "guarantee"])
case("constants: reason floor 20, hash width 8, incident anchor span 300",
     lambda: (r.REASON_MIN, r.HASH_WIDTH, r.INCIDENT_SPAN), (20, 8, 300))
case("constants: the threshold table carries the R5 names and defaults",
     lambda: [(t.env, t.default) for t in r.THRESHOLD_SPECS],
     [("ZUVO_COMMENT_MAX_DENSITY", 0.30), ("ZUVO_COMMENT_MIN_LINES", 20), ("ZUVO_COMMENT_BLOCK_MIN", 4),
      ("ZUVO_COMMENT_JUSTIFY_MAX", 2)])
case("constants: one action hint per rule",
     lambda: r.HINTS, {"D": "delete comments that restate the code",
                       "N": "move the history to the commit message or a runbook; keep only the current constraint",
                       "L": "cut to the WHY, or delete it if it restates the code"})

ALLOWED_IMPORTS = {"__future__", "bisect", "collections", "dataclasses", "hashlib", "itertools", "re", "typing",
                   "zuvo_comment_scan"}
SOURCE = os.path.join(sys.argv[1], "zuvo_comment_rules.py")
case("driver: the modules under test are the checkout's scripts/zuvo-home files",
     lambda: [os.path.realpath(m.__file__) for m in (r, sys.modules["zuvo_comment_scan"])],
     [os.path.realpath(os.path.join(sys.argv[1], name)) for name in ("zuvo_comment_rules.py", "zuvo_comment_scan.py")])

@check("purity: the module imports only stdlib helpers and the scanner, and calls no open/print/input/eval/exec")
def purity():
    with open(SOURCE, encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    imported = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
    imported |= {n.module.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module}
    calls = {n.func.id for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
    problems = ["imports %s" % sorted(imported - ALLOWED_IMPORTS)] if imported - ALLOWED_IMPORTS else []
    io_calls = calls & {"open", "print", "input", "eval", "exec"}
    return problems + (["calls %s" % sorted(io_calls)] if io_calls else [])

@check("self: the rules module passes its own rules with every line authored")
def self_audit():
    with open(SOURCE, encoding="utf-8") as handle:
        res = audit(handle.read(), path="zuvo_comment_rules.py")
    return ["%s %s line %d: %s" % (f.rule, f.sub, f.line, f.text) for f in res.findings]

@check("perf: a 120 000-char comment without '/' and 400 'incident' lines of filler each take < %d s"
       % PERF_SECONDS)
def perf():
    slow = []
    for name, src in (("long token", "x = 0\n# " + "a" * 120000 + "\ny = 1\n"),
                      ("incident lines", "x = 0\n" + ("# incident " + "b " * 500 + "\n") * 400 + "y = 1\n")):
        start = time.perf_counter()
        audit(src)
        took = time.perf_counter() - start
        slow += ["%s took %.1f s" % (name, took)] if took >= PERF_SECONDS else []
    return slow

# ---- fuzz (fixed seeds, printed with any failing input) --------------------------------------------------
LINE_BITS = ["x = 1", "    y = 2", "", "# previously alpha", "# a", "#", "// b", "// outage OPS-1", "/*", " * c",
             " */", '"""doc', '"""', "def f():", "function g() {", "}", "  return 1;", "@wrap", "# within 5 s",
             "x = 1  # hotfix", "<?php", "package main", "=begin", "=end", "'", '"', "`", "\t", "é # 50%",
             "// Oracle: spec", "# 2026-01-02", "cat <<EOF", "EOF", "# Jan 2026", "# zmierzone w a/b"]
ID_SHAPE = re.compile(r"[NL]:%s:[0-9a-f]{8}|D:%s" % (re.escape(PATH), re.escape(PATH)))

def invariants(res, n, added, carried, th):
    authored = {row for row in added if 0 <= row < n and row not in carried}
    total = res.authored_comment + res.authored_code
    gated = total >= th["min_lines"].value
    problems = [] if total <= len(authored) else ["authored %d > %d rows" % (total, len(authored))]
    if res.carried != len({row for row in added if 0 <= row < n and row in carried}):
        problems.append("carried %d" % res.carried)
    if (res.density is None) == gated or (gated and res.density != res.authored_comment / total):
        problems.append("density %r for %d/%d" % (res.density, res.authored_comment, total))
    if any(f.rule == "D" for f in res.findings) != bool(gated and res.density > th["density"].value):
        problems.append("D finding does not match density %r" % res.density)
    for f in res.findings:
        if not ID_SHAPE.fullmatch(f.id) or not 1 <= f.line <= n or (f.rule == "N" and f.line - 1 not in authored):
            problems.append("finding %r" % (f,))
    if len({f.id for f in res.findings}) != len(res.findings):
        problems.append("duplicate ids")
    return problems + ["claim %r" % (c,) for c in res.claims if c.line - 1 not in authored]

def shift_problems(lang, text, added, carried, th, first):
    if text.startswith(("#!", "\ufeff")): return []
    up = [frozenset(row + 1 for row in rows if row >= 0) for rows in (added, carried)]
    moved = r.evaluate(r.FileView(path=PATH, lang=lang, text="\n" + text, added=up[0], carried=up[1]), th)
    want = [(f.id, f.rule, f.sub, f.line + 1) for f in first.findings] + [(c.line + 1, c.text) for c in first.claims]
    got = [(f.id, f.rule, f.sub, f.line) for f in moved.findings] + [(c.line, c.text) for c in moved.claims]
    return equal(got, want) + equal((moved.authored_comment, moved.authored_code, moved.density),
                                    (first.authored_comment, first.authored_code, first.density))

def fuzz_evaluate(lang, seed):
    rng = random.Random(seed)
    for _ in range(FUZZ_INPUTS):
        text = "\n".join(rng.choice(LINE_BITS) for _ in range(rng.randint(0, 30)))
        text += "\n" if rng.random() < 0.8 else ""
        n = len(s.split_lines(text))
        added = {row for row in range(-2, n + 3) if rng.random() < 0.7}
        carried = {row for row in added if rng.random() < 0.2}
        th = r.load_thresholds(rng.choice([{}, TIGHT]))
        try:
            first = r.evaluate(r.FileView(PATH, lang, text, frozenset(added), frozenset(carried)), th)
            again = r.evaluate(r.FileView(PATH, lang, text, set(sorted(added, reverse=True)), set(carried)), th)
            problems = invariants(first, n, added, carried, th) + equal(again, first)
            problems += shift_problems(lang, text, added, carried, th, first)
        except Exception as exc:
            return ["seed %d input %r raised %r" % (seed, text, exc)]
        if problems:
            return ["seed %d input %r: %s" % (seed, text, "; ".join(problems))]
    return []

VOCAB = ["# a", "#  a", "x = 1", "  x = 1", "", "   ", "# b", "y"]

def fuzz_carried(seed):
    rng = random.Random(seed)
    for _ in range(FUZZ_INPUTS):
        files = {name: {row: rng.choice(VOCAB) for row in rng.sample(range(40), rng.randint(0, 8))}
                 for name in rng.sample(["a.py", "b.py", "c/d.py", "e=f.py"], rng.randint(0, 4))}
        removed = [rng.choice(VOCAB) for _ in range(rng.randint(0, 10))]
        flipped = {name: dict(reversed(list(rows.items()))) for name, rows in reversed(list(files.items()))}
        try:
            got, again = r.carried_lines(files, removed), r.carried_lines(flipped, iter(removed))
        except Exception as exc:
            return ["seed %d input %r raised %r" % (seed, (files, removed), exc)]
        pool = Counter(" ".join(t.split()) for t in removed if t.strip())
        wanted = Counter(" ".join(t.split()) for rows in files.values() for t in rows.values() if t.strip())
        expected = sum(min(count, pool[key]) for key, count in wanted.items())
        problems = equal(again, got) + equal(set(got), set(files))
        problems += ["%s carried %r outside its rows" % (p, got[p]) for p in got if not got[p] <= set(files.get(p, {}))]
        problems += equal(sum(len(rows) for rows in got.values()), expected)
        if problems:
            return ["seed %d input %r: %s" % (seed, (files, removed), "; ".join(problems))]
    return []

for f_index, f_lang in enumerate(FUZZ_LANGS):
    CHECKS.append(("fuzz: evaluate on %s — %d seeded inputs never raise, keep invariants and stable ids"
                   % (f_lang, FUZZ_INPUTS), lambda lang=f_lang, seed=20261002 + f_index: fuzz_evaluate(lang, seed)))
CHECKS.append(("fuzz: carried_lines — %d seeded diffs never raise and match the multiset intersection" % FUZZ_INPUTS,
               lambda: fuzz_carried(20261102)))

def report(name, run):
    try:
        problems = run()
    except (Exception, SystemExit) as exc:
        problems = ["raised %r" % exc]
    if not isinstance(problems, list):
        problems = ["returned %r instead of a list of problems" % (problems,)]
    print(("NO %s: %s" % (name, "; ".join(problems))) if problems else "OK " + name)
    return not problems

@check("driver: a check that raises any exception, exits or returns a non-list fails alone and the run goes on")
def isolation():
    with contextlib.redirect_stdout(io.StringIO()) as sink:
        got = [report("probe", run) for run in (lambda: {}["missing"], lambda: sys.exit(3), lambda: "x")]
    return equal((got, [line[:9] for line in sink.getvalue().splitlines()]), ([False] * 3, ["NO probe:"] * 3))


print("DECLARED %d" % len(CHECKS))
verdicts = [report(name, fn) for name, fn in CHECKS]
print("TOTAL %d" % len(verdicts))
sys.exit(0 if all(verdicts) else 1)
PY
out="$(python3 "$TMP/driver.py" "$HELPERS" 2>&1)"; rc=$?

[ "$rc" -eq 0 ] && pass "the case driver exited 0 (no crash, no NO verdict)" || bad "the case driver exited $rc"
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
seen=0; total=""; declared=""
while IFS= read -r line; do
  case "$line" in
    "OK "*) pass "${line#OK }"; seen=$((seen + 1)) ;;
    "NO "*) bad "${line#NO }"; seen=$((seen + 1)) ;;
    "DECLARED "*) declared="${line#DECLARED }" ;;
    "TOTAL "*) total="${line#TOTAL }" ;;
    *) printf '  %s\n' "$line" ;;
  esac
done < <(printf '%s\n' "$out")
if is_int "$declared" && is_int "$total" && [ "$declared" -ge 133 ] && [ "$seen" -eq "$total" ] \
  && [ "$total" -eq "$declared" ]; then
  pass "every declared case reported one verdict ($seen)"
else
  bad "verdicts $seen, TOTAL [$total], DECLARED [$declared] — they must be equal integers, DECLARED >= 133"
fi

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"
exit "$fail"
