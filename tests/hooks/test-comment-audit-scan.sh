#!/usr/bin/env bash
# Contract for scripts/zuvo-home/zuvo_comment_scan.py: which lines comment-audit counts as comments.
# A string, heredoc, regex literal or pragma read as a comment would push the pass to delete code or
# inflate density, so every language's traps are pinned line by line.
# Level: small (Q20) — in-process calls of the module's pure functions in one python driver; no git, no
# network, no sleep. The only file is the driver itself, written to mktemp.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || { echo "FAIL: cannot resolve the repo root"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
HELPERS="$ROOT/scripts/zuvo-home"
fail=0
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1

TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Kinds are written one letter per line: C code, # comment, M code + comment, . blank.
cat > "$TMP/driver.py" <<'PY'
import ast
import faulthandler
import glob
import os
import random
import re
import sys

HANG_SECONDS = 600
faulthandler.dump_traceback_later(HANG_SECONDS, exit=True)
sys.path.insert(0, sys.argv[1])
import zuvo_comment_scan as s

LETTER = {"code": "C", "comment": "#", "mixed": "M", "blank": "."}
CASES, DETECTS, CHECKS = [], [], []
FUZZ_INPUTS = 300
FUZZ_LANGS = ("python", "sh", "ruby", "js", "jsx", "ts", "tsx", "go", "php")
POLY = "''''exec \"$(command -v python3 || command -v python || echo python3)\" \"$0\" \"$@\" # '''"
BOM = "\ufeff"


def case(name, lang, src, want, *, texts, doc=frozenset(), degraded=False):
    CASES.append((name, lang, src, want, texts, doc, degraded))


def detect(name, triples):
    DETECTS.append((name, triples))


def ext(*pairs):
    return [("dir/a" + e, [], want) for e, want in pairs]


detect("detect: .py is python", ext((".py", "python")))
detect("detect: .sh .bash .zsh .bats are sh", ext((".sh", "sh"), (".bash", "sh"), (".zsh", "sh"), (".bats", "sh")))
detect("detect: .rb .rake are ruby", ext((".rb", "ruby"), (".rake", "ruby")))
detect("detect: .js .mjs .cjs are js, .jsx is jsx", ext((".js", "js"), (".mjs", "js"), (".cjs", "js"), (".jsx", "jsx")))
detect("detect: .ts .mts .cts are ts, .tsx is tsx", ext((".ts", "ts"), (".mts", "ts"), (".cts", "ts"), (".tsx", "tsx")))
detect("detect: .go is go, .php is php", ext((".go", "go"), (".php", "php")))
detect("detect: .rs .java .yml .sql are n/a", ext((".rs", "n/a"), (".java", "n/a"), (".yml", "n/a"), (".sql", "n/a")))
detect("detect: a BOM or a trailing CR does not hide the first line",
       [("t", [BOM + "#!/usr/bin/env python3"], "python"), ("t", ["#!/bin/sh\r"], "sh"),
        ("t", [BOM + POLY], "python")])
detect("detect: BSD env -P skips its path argument", [("t", ["#!/usr/bin/env -P /usr/local/bin python3"], "python")])
detect("detect: .md .json .vue .yaml .svelte .astro are n/a",
       ext((".md", "n/a"), (".json", "n/a"), (".vue", "n/a"), (".yaml", "n/a"), (".svelte", "n/a"), (".astro", "n/a")))
detect("detect: the extension decides case-insensitively", [("A.PY", [], "python"), ("b.Sh", [], "sh")])
detect("detect: an extension wins over a shebang", [("notes.md", ["#!/bin/sh"], "n/a")])
detect("detect: extensionless polyglot (sh shebang + exec line) is python", [("tool", ["#!/bin/sh", "# x", POLY], "python")])
detect("detect: extensionless python shebangs", [("t", ["#!/usr/bin/env python3"], "python"), ("t", ["#!/usr/bin/python3.11"], "python")])
detect("detect: extensionless sh-family shebangs",
       [("t", ["#!/bin/bash"], "sh"), ("t", ["#!/usr/bin/env -S bash -e"], "sh"), ("t", ["#!/usr/bin/env bats"], "sh"),
        ("t", ["#! /bin/sh"], "sh"), ("t", ["#!/bin/zsh"], "sh")])
detect("detect: extensionless ruby shebang", [("t", ["#!/usr/bin/env ruby"], "ruby")])
detect("detect: extensionless non-script is n/a",
       [("Makefile", ["all:", "\techo hi"], "n/a"), ("t", [], "n/a"), ("t", ["#!/usr/bin/env node"], "n/a")])
detect("detect: env skips -S options and NAME=value words",
       [("t", ["#!/usr/bin/env -S VAR=1 python3 -u"], "python"), ("t", ["#!/usr/bin/env PYTHONPATH=lib python3"], "python")])
detect("detect: env skips the argument of -u, --unset=, -C and --chdir=",
       [("t", ["#!/usr/bin/env -u PYTHONPATH python3"], "python"), ("t", ["#!/usr/bin/env --unset=X ruby"], "ruby"),
        ("t", ["#!/usr/bin/env -C /tmp bash"], "sh"), ("t", ["#!/usr/bin/env --chdir=/tmp python3"], "python")])
detect("detect: env -S splits its string", [("t", ["#!/usr/bin/env -S 'python3 -u'"], "python"),
                                             ("t", ["#!/usr/bin/env -S bash -e"], "sh"),
                                             ("t", ["#!/usr/bin/env -S 'PYTHONPATH=lib python3 -u'"], "python")])
detect("detect: an unclosed quote in a shebang falls back to whitespace words and still names the interpreter",
       [("t", ['#!/usr/bin/python3 -c "unclosed'], "python"), ("t", ["#!/bin/sh -c 'x"], "sh"),
        ("t", ["#!/usr/bin/env -S python3 'unclosed"], "python")])
detect("detect: a quote glued to the interpreter by a malformed env -S string names no interpreter",
       [("t", ["#!/usr/bin/env -S 'python3 -u"], "n/a")])
detect("detect: a shebang with no interpreter, or env with nothing to run, is n/a",
       [("t", ["#!"], "n/a"), ("t", ["#!/usr/bin/env"], "n/a"), ("t", ["#!/usr/bin/env -i"], "n/a"),
        ("t", ["#!/usr/bin/env -u"], "n/a")])
detect("detect: only the first 10 lines are read", [("t", [""] * 9 + [POLY], "python"), ("t", [""] * 10 + [POLY], "n/a")])

case("python: '#' inside a string is code", "python", 'x = "# not a comment"\n', "C", texts={})
case("python: a multi-line string assigned to a name is code", "python", "y = '''a\n# b\n'''\n", "CCC", texts={})
case("python: a docstring is comment lines flagged doc, quotes stripped", "python",
     'def f():\n    """Return one.\n\n    Longer text.\n    """\n    return 1\n', "C####C",
     texts={1: "Return one.", 2: "", 3: "Longer text.", 4: ""}, doc={1, 2, 3, 4})
case("python: a comment line", "python", "# c\nx = 1\n", "#C", texts={0: "c"}, doc=set())
case("python: code with a trailing comment is mixed", "python", "x = 1  # c\n", "M", texts={0: "c"})
case("python: a shebang on line 1 is code", "python", "#!/usr/bin/env python3\n# c\n", "C#", texts={1: "c"})
case("python: '#!' on line 2 is a comment", "python", "x = 1\n#!not a shebang\n", "C#", texts={1: "not a shebang"})
case("python: an unterminated triple quote degrades to the '#' scanner, no exception", "python",
     'x = 1\n"""never closed\n# c\n', "CCC", texts={}, degraded=True)
case("python: the fallback keeps a triple-quoted block open across lines", "python",
     'def f():\n    """Doc line\n    # not a comment\n    """\n    x = 1\n  y = 2\n', "CCCCCC", texts={}, degraded=True)
case("python: polyglot header — exec line is code, the docstring is doc", "python",
     "#!/bin/sh\n" + POLY + '\n"""Tool summary."""\nimport os\n', "CC#C", texts={2: "Tool summary."}, doc={2})
case("python: coding, noqa, type: ignore, pragma: no cover and fmt: off/on are code", "python",
     "# -*- coding: utf-8 -*-\nimport os  # noqa: F401\nx = f()  # type: ignore[attr-defined]\n"
     "if y:  # pragma: no cover\n    pass\n# fmt: off\n# noqa: E501\n# fmt: on\n", "CCCCCCCC", texts={})
case("python: prose before an inner directive is still a comment", "python", "# explain why  # noqa: E501\n", "#",
     texts={0: "explain why"})
case("python: code, prose and a directive make a mixed row", "python", "x = 1  # because foo  # noqa\n", "M",
     texts={0: "because foo"})
case("python: a directive-only trailing comment keeps the row code", "python", "x = 1  # noqa\n", "C", texts={})
case("python: a pragma word inside prose stays a comment", "python", "# see the noqa docs\n", "#",
     texts={0: "see the noqa docs"})
case("python: an empty line is blank", "python", "x = 1\n\ny = 2\n", "C.C", texts={})
case("python: CRLF line endings keep one kind per line", "python", "x = 1\r\n# c\r\n", "C#", texts={1: "c"})
case("python: a lone CR inside a line does not hide its comment", "python", "x = 1\r# c\n", "M", texts={0: "c"})
case("python: a lone CR before a non-ASCII letter does not crash tokenize", "python", "x = 1\r\u00e9  # c\n", "M",
     texts={0: "c"})
case("python: a control character falls back without losing the comment", "python", "a = 1\x0b# c\n", "M",
     texts={0: "c"}, degraded=True)
case("python: NUL after an indented line falls back instead of crashing tokenize", "python", " a\n\x00\n", "CC",
     texts={}, degraded=True)
case("python: '#' inside a string stays code in the fallback scanner", "python",
     "x = \"a # b\"\ny = 'c # d'  # e\nq = 1\x0b\n", "CMC", texts={1: "e"}, degraded=True)
case("python: in the fallback scanner a string ending in an odd run of backslashes continues; '#' there is code",
     "python", "s = 'a\\\n# still string'\nt = \"b\\\\\\\n# still\"\nx = 1  # c\n\x00\n", "CCCCMC",
     texts={4: "c"}, degraded=True)
case("python: in the fallback scanner an even run of backslashes ends the unterminated string at the line end",
     "python", "s = 'a\\\\\n# c\n\x00\n", "C#C", texts={1: "c"}, degraded=True)
case("python: '#' inside f-strings is code", "python", 'x = f"a # b"\ny = f"{x}#{y}"\nz = rf"\\d # w"\n', "CCC",
     texts={})
case("python: a multi-line f-string keeps '#' as code", "python", 'x = f"""\n# not a comment {y}\n"""\n', "CCC",
     texts={})
case("python: comments inside brackets", "python", "x = [\n    1,  # one\n    # two\n]\n", "CM#C",
     texts={1: "one", 2: "two"})

case("sh: '#' inside double and single quotes is code", "sh", "echo \"a # b\"\necho 'a # b'\n", "CC", texts={})
case("sh: ${#...}, $# and x=foo#bar are code", "sh", "n=${#arr[@]}\necho $#\nx=foo#bar\n", "CCC", texts={})
case("sh: an escaped hash is code", "sh", "echo \\# x\n", "C", texts={})
case("sh: a command then a comment is mixed", "sh", "ls -l # list\n", "M", texts={0: "list"})
case("sh: a quoted heredoc body is code until its terminator", "sh", "cat <<'EOF'\n# x\nEOF\n# after\n", "CCC#",
     texts={3: "after"})
case("sh: a double-quoted heredoc word", "sh", 'cat <<"EOF"\n# x\nEOF\n# c\n', "CCC#", texts={3: "c"})
case("sh: a <<- heredoc closes on a tab-indented terminator", "sh", "\tcat <<-EOF\n\t# body\n\tEOF\n# after\n", "CCC#",
     texts={3: "after"})
case("sh: a heredoc with a space before its word", "sh", "cat << EOF\n# x\nEOF\n# c\n", "CCC#", texts={3: "c"})
case("sh: a comment after a heredoc opener is still a comment", "sh", "cat <<EOF # note\nbody\nEOF\n", "MCC",
     texts={0: "note"})
case("sh: two heredocs on one line are read in order", "sh", "paste <<A <<B\n# a\nA\n# b\nB\n# c\n", "CCCCC#",
     texts={5: "c"})
case("sh: an unclosed heredoc is degraded", "sh", "cat <<EOF\nbody\n", "CC", degraded=True, texts={})
case("sh: a <<< here-string is not a heredoc", "sh", "read -r a <<< word\n# c\n", "C#", texts={1: "c"})
case("sh: an arithmetic shift is not a heredoc", "sh", "echo $((x<<n))\n# c\n", "C#", texts={1: "c"})
case("sh: (( )) at a word start is arithmetic", "sh", "(( x = y << z ))\n# c\n", "C#", texts={1: "c"})
case("sh: $(( )) inside a double-quoted string is arithmetic", "sh", 'echo "$((a << b))"\n# c\n', "C#", texts={1: "c"})
case("sh: $'...' allows an escaped quote", "sh", "echo $'it\\'s # no'\n# c\n", "C#", texts={1: "c"})
case("sh: a backtick substitution is one token", "sh", 'x=`echo "a # b"` # c\n', "M", texts={0: "c"})
case("sh: ';', '|', '&' and '(' start a word before '#'", "sh", "a;# c\nb|# c\nd&# c\n(# c\n)\n", "MMMMC",
     texts={0: "c", 1: "c", 2: "c", 3: "c"})
case("sh: a comment inside nested $( $( ) )", "sh", "x=$( a $( b ) # c\n)\n", "MC", texts={0: "c"})
case("sh: quote state carries across lines", "sh", 'msg="one\n# still in the string\n"\n# c\n', "CCC#", texts={3: "c"})
case("sh: nested quotes inside $( ) in a string", "sh", 'echo "$(printf "a # b")" # c\n', "M", texts={0: "c"})
case("sh: a shebang is code, the next comment is not", "sh", "#!/bin/bash\n# c\n", "C#", texts={1: "c"})
case("sh: a shellcheck directive is code", "sh", "# shellcheck disable=SC2086\necho $x\n", "CC", texts={})

case("ruby: the << operator with a space is not a heredoc", "ruby", "items << value\n# c\n", "C#", texts={1: "c"})
case("ruby: interpolation with nested quotes stays inside the string", "ruby",
     's = "#{x}"\nt = "#{h["k"]} # no"\n', "CC", texts={})
case("ruby: =begin/=end is a comment block", "ruby", "=begin\ntext here\n=end\nx = 1\n", "###C",
     texts={0: "", 1: "text here", 2: ""})
case("ruby: =begin may carry text after a space", "ruby", "=begin docs\ntext\n=end\n", "###",
     texts={0: "", 1: "text", 2: ""})
case("ruby: an indented =begin is code", "ruby", "  =begin\n# c\n", "C#", texts={1: "c"})
case("ruby: =begin needs a space or the line end after it", "ruby", "=beginx\n# c\n", "C#", texts={1: "c"})
case("ruby: a squiggly heredoc body is code", "ruby", "s = <<~EOS\n  # x\n  EOS\n# c\n", "CCC#", texts={3: "c"})
case("ruby: a <<- heredoc closes on an indented terminator", "ruby", "s = <<-EOS\n  # x\n  EOS\n# c\n", "CCC#",
     texts={3: "c"})
case("ruby: a plain heredoc closes at column 0", "ruby", "s = <<EOS\n# x\nEOS\n# c\n", "CCC#", texts={3: "c"})
case("ruby: a quoted heredoc word", "ruby", "s = <<~'EOS'\n  # x\n  EOS\n# c\n", "CCC#", texts={3: "c"})
case("ruby: << right after a name, ')' or ']' appends", "ruby", "arr<<x\nfoo(a)<<b\nitems[0]<<v\n# c\n", "CCC#",
     texts={3: "c"})
case("ruby: <<ID after '(' or after a space is a heredoc", "ruby", "puts(<<EOS)\n# x\nEOS\nfoo <<EOT\n# y\nEOT\n# c\n",
     "CCCCCC#", texts={6: "c"})
case("ruby: an unclosed heredoc is degraded", "ruby", "s = <<~EOS\n  body\n", "CC", degraded=True, texts={})
case("ruby: '#' inside percent literals is code", "ruby",
     "x = %w[a #b c] # c\ny = %q(a (b) #c)\nz = %Q|a #{b} #c|\nr = %r{a#{x}#b}\nt = %(a #b)\n", "MCCCC", texts={0: "c"})
case("ruby: a percent literal spans lines", "ruby", "x = %w[\n  a #b\n] # c\n", "CCM", texts={2: "c"})
case("ruby: '%' after an operand is modulo, not a literal", "ruby", "x = a %(b # c\n", "M", texts={0: "c"})
case("ruby: the ?# character literal is code", "ruby", "c = ?# # c\n", "M", texts={0: "c"})
case("ruby: a regex in operand position is code, '/' after an operand divides", "ruby",
     "if /a #b/ =~ s # c\nx = a / b # d\n", "MM", texts={0: "c", 1: "d"})
case("ruby: an unterminated =begin is degraded", "ruby", "=begin\nopen\n", "##", texts={0: "", 1: "open"},
     degraded=True)
case("ruby: an escaped quote in a single-quoted string", "ruby", "s = 'it\\'s # no'\n# c\n", "C#", texts={1: "c"})
case("ruby: a trailing comment is mixed", "ruby", "x = 1 # c\n", "M", texts={0: "c"})

case("js: '//' inside a string is code", "js", 'const u = "http://x";\n', "C", texts={})
case("js: '//' inside a template ${} string is code", "js", 'const t = `a ${ "//" } b`;\n', "C", texts={})
case("js: a multi-line template keeps '//' as code", "js", "const t = `a\n// not a comment\n`;\n", "CCC", texts={})
case("js: a backtick in a string inside ${} does not end the template", "js",
     'const t = `a ${ "`" } b`; // c\n', "M", texts={0: "c"})
case("js: braces inside ${} do not end the template", "js", 'const t = `${ {a: 1}.b ? "`" : 0 }`; // c\n', "M",
     texts={0: "c"})
case("js: an escaped backtick does not end the template", "js", "const t = `a \\` // b`; // c\n", "M", texts={0: "c"})
case("js: a template nested in ${}", "js", "const t = `a ${ `in ${x} // y` } b`; // c\n", "M", texts={0: "c"})
case("js: '/' after a postfix ++ or -- (after a name or ']') divides, so the trailing comment stays", "js",
     "x = i++ / n; // total\ny = i-- / 2; // half\nz = a[0]++ / 3; // third\n", "MMM",
     texts={0: "total", 1: "half", 2: "third"})
case("ts: '/' after a postfix ++ divides", "ts", "x = i++ / n; // total\n", "M", texts={0: "total"})
case("js: a prefix ++ or -- still expects an operand, so '/' after it opens a regex", "js",
     "x = ++/'/.lastIndex; // c\ny = --i / 2; // d\n", "MM", texts={0: "c", 1: "d"})
case("js: 'a++ /re/.test(x)' (a syntax error in JS) keeps its trailing comment", "js", "a++ /re/.test(x) // c\n", "M",
     texts={0: "c"})
case("js: '/' at the start of ${} opens a regex", "js", "const t = `${ /`/.test(s) }`; // c\n", "M", texts={0: "c"})
case("jsx: '/' at the start of a {expr} opens a regex", "jsx", "const a = <p>{/`/.test(s)}</p>; // c\n", "M",
     texts={0: "c"})
case("js: code with an inline /* c */ is mixed", "js", "f(/* c */ 1);\n", "M", texts={0: "c"})
case("js: an unclosed template is degraded", "js", "const t = `open\n// x\n", "CC", degraded=True, texts={})
case("js: a regex literal with escaped slashes is code", "js", "/\\/\\/ re/.test(s);\n", "C", texts={})
case("js: a slash inside a regex character class does not end the regex", "js", "const r = /[///]/; f();\n", "C",
     texts={})
case("js: a regex after return", "js", "return /#|\\/\\//.test(s); // c\n", "M", texts={0: "c"})
case("js: a regex left open at the line end is degraded", "js", "x = /abc\n// c\n", "C#", degraded=True, texts={1: "c"})
case("js: division then a comment is mixed", "js", "x = a / b // c\n", "M", texts={0: "c"})
case("js: division after ')' is not a regex", "js", "x = (a) / 2; // c\n", "M", texts={0: "c"})
case("js: an escaped quote does not end the string", "js", "const a = 'it\\'s // not';\n", "C", texts={})
case("js: a quote left open at the line end is degraded", "js", 'const a = "x\n// c\n', "C#", degraded=True,
     texts={1: "c"})
case("js: a backslash at the line end continues the string, so '//' on the next line is string", "js",
     'const a = "x\\\n// c";\n', "CC", texts={})
case("ts: a continued single-quoted string closes on the next line, before its trailing comment", "ts",
     "const b = 'x\\\n// c'; // d\n", "CM", texts={1: "d"})
case("js: a multi-line block comment", "js", "/*\n * one\n */\nx();\n", "###C", texts={0: "", 1: "one", 2: ""})
case("js: an empty line inside a block comment stays in the comment", "js", "/*\n\n * two\n */\n", "####",
     texts={0: "", 1: "", 2: "two", 3: ""})
case("js: an unterminated block comment is degraded", "js", "x();\n/* open\n", "C#", texts={1: "open"}, degraded=True)
case("js: prose before an inner directive is still a comment", "js", "// keep this short // eslint-disable-line\n", "#",
     texts={0: "keep this short"})
case("js: a directive-only comment is code", "js", "// eslint-disable-next-line\n", "C", texts={})
case("js: a pragma word inside prose stays a comment", "js", "// read eslint-disable docs\n", "#",
     texts={0: "read eslint-disable docs"})
case("jsx: JSX text with a URL is code", "jsx", "const el = (\n  <p>see http://example.com</p>\n);\n", "CCC", texts={})
case("tsx: JSX text with a URL is code", "tsx", "const el = (\n  <p>see http://example.com</p>\n);\n", "CCC", texts={})
case("jsx: '//' after a {expr} is JSX text", "jsx", "const a = (\n  <p>{value} // t</p>\n);\n", "CCC", texts={})
case("jsx: a comment inside a {expr} is a comment", "jsx", "const a = (\n  <p>{x // c\n  }</p>\n);\n", "CMCC",
     texts={1: "c"})
case("jsx: {/* c */} inside JSX", "jsx", "const a = <div>{/* c */}</div>;\n", "M", texts={0: "c"})
case("jsx: nested elements keep later text inside the outer one", "jsx",
     "const a = (\n  <div><span>a</span> // b</div>\n);\n// c\n", "CCC#", texts={3: "c"})
case("jsx: a self-closing tag opens no element", "jsx", "const a = (\n  <br/>\n);\n// c\n", "CCC#", texts={3: "c"})
case("jsx: a fragment is an element", "jsx", "const a = (\n  <>see http://x</>\n);\n// c\n", "CCC#", texts={3: "c"})
case("jsx: an attribute string holding '//' is code", "jsx", 'const a = <a href="http://x">t</a>; // c\n', "M",
     texts={0: "c"})
case("jsx: a closing tag without '>' is degraded", "jsx", "const a = (\n  <div>x</div\n);\n", "CCC", degraded=True,
     texts={})
case("jsx: an unclosed element is degraded", "jsx", "const a = (\n  <div>\n", "CC", degraded=True, texts={})
case("ts: a <T> cast is not JSX", "ts", "const y = <T>x; // c\n", "M", texts={0: "c"})
case("tsx: <T,> type parameters are not a tag", "tsx", "const f = <T,>(x: T) => x; // c\n", "M", texts={0: "c"})
case("tsx: <T extends ...> type parameters are not a tag", "tsx", "const g = <T extends object>(x: T) => x; // c\n", "M",
     texts={0: "c"})
case("tsx: a generic call is code", "tsx", "const r = useRef<HTMLDivElement>(null); // c\n", "M", texts={0: "c"})
case("ts: ts, eslint, istanbul, vitest, reference, c8 and prettier pragmas are code", "ts",
     "// @ts-expect-error\n// eslint-disable-next-line no-console\n/* istanbul ignore next */\n"
     "// @vitest-environment jsdom\n/// <reference types=\"node\" />\n/* c8 ignore next */\n// prettier-ignore\n"
     "// @ts-ignore\n// @ts-nocheck\n/* eslint-enable */\n", "CCCCCCCCCC", texts={})
case("js: @jest-environment inside a docblock is code", "js", "/**\n * @jest-environment jsdom\n */\n", "#C#",
     texts={0: "", 2: ""})

case("go: a raw string with '//' is code", "go", "s := `raw // not`\n", "C", texts={})
case("go: a multi-line raw string is code", "go", "s := `a\n// b\n`\n", "CCC", texts={})
case("go: an interpreted string cannot span lines", "go", 's := "abc\n// c\n', "C#", texts={1: "c"}, degraded=True)
case("go: '/' is always division", "go", "x := a / b // c\nv := (/ 2) // d\n", "MM", texts={0: "c", 1: "d"})
case("go: prose before //nolint is still a comment", "go", "// explain //nolint:errcheck\n", "#", texts={0: "explain"})
case("go: build, generate and nolint directives are code", "go",
     "//go:build linux\n//go:generate stringer -type=X\nx := f() //nolint:errcheck\n", "CCC", texts={})
case("go: a rune holding a quote, then a comment", "go", "c := '\"' // c\n", "M", texts={0: "c"})

case("php: #[Attr] is code, # c is a comment", "php", "<?php\n#[Attr]\n# c\n", "CC#", texts={2: "c"})
case("php: a nowdoc body is code", "php", "<?php\n$s = <<<'EOT'\n# x\n// y\nEOT;\n# c\n", "CCCCC#", texts={5: "c"})
case("php: a heredoc closes on an indented terminator", "php", "<?php\n$s = <<<EOT\n    # x\n    EOT;\n# c\n", "CCCC#",
     texts={4: "c"})
case("php: HTML outside <?php is code", "php", '<p>http://x</p>\n<?php\n// c\n?>\n<a href="//cdn">x</a>\n', "CC#CC",
     texts={2: "c"})
case("php: a // comment ends at ?>", "php", "<?php // c ?> <b>//x</b>\n", "M", texts={0: "c"})
case("php: a # comment ends at ?>", "php", "<?php # c ?> <b>#x</b>\n", "M", texts={0: "c"})
case("php: <?= opens PHP", "php", "<p><?= $x // c ?></p>\n", "M", texts={0: "c"})
case("php: strings span lines", "php", "<?php\n$s = 'a\n// not\n';\n", "CCCC", texts={})
case("php: a multi-line SQL string keeps '//' inside it", "php",
     '<?php\n$sql = "SELECT *\n  FROM t // x\n  WHERE a = 1";\n', "CCCC", texts={})
case("php: '/' is always division", "php", "<?php\n$x = $a / $b; // c\n$y = (/ 2); // d\n", "CMM",
     texts={1: "c", 2: "d"})
case("php: a backtick string is code", "php", "<?php\n$out = `ls // x`; // c\n", "CM", texts={1: "c"})
case("php: phpstan and psalm annotations are code", "php",
     "<?php\n/** @phpstan-param int $x */\n// @psalm-suppress MixedAssignment\n", "CCC", texts={})

case("classify: a text without a trailing newline keeps its last line", "python", "x = 1\n# c", "C#", texts={1: "c"})
case("classify: empty text has no lines", "python", "", "", texts={}, doc=set())
case("classify: a leading BOM does not change the first line", "python", BOM + "# c\nx = 1\n", "#C", texts={0: "c"})
case("classify: a text that is only a BOM keeps its one line", "python", BOM, ".", texts={})


def check(name):
    def register(fn):
        CHECKS.append((name, fn))
        return fn
    return register


@check("split_lines: empty text is no line, a lone LF is one empty line, CRLF counts once")
def split_rule():
    got = [s.split_lines(""), s.split_lines("\n"), s.split_lines("a\r\nb")]
    return [] if got == [[], [""], ["a", "b"]] else ["got %r" % got]


@check("driver: the module under test is the checkout's scripts/zuvo-home/zuvo_comment_scan.py")
def module_path():
    want = os.path.realpath(os.path.join(sys.argv[1], "zuvo_comment_scan.py"))
    return [] if os.path.realpath(s.__file__) == want else ["imported %s" % s.__file__]


def equal(got, want):
    return [] if got == want else ["got %r, want %r" % (got, want)]


def refusal(lang):
    try:
        s.classify("x", lang)
    except ValueError as exc:
        return str(exc)
    return "no ValueError"


@check("classify: an unsupported language, the n/a sentinel and the empty name included, raises ValueError naming it")
def refuses():
    return equal([refusal(lang) for lang in ("cobol", s.UNSUPPORTED, "")],
                 ["unsupported language: 'cobol'", "unsupported language: 'n/a'", "unsupported language: ''"])


def with_tokenizer(stand_in, call):
    original = s.tokenize.generate_tokens
    s.tokenize.generate_tokens = stand_in
    try:
        return call()
    finally:
        s.tokenize.generate_tokens = original


@check("classify: any exception tokenize raises falls back with degraded=True and keeps every row")
def tokenize_failures():
    text, problems = "x = 1\n# c\n", []
    for error in (s.tokenize.TokenError, SyntaxError, SystemError, UnicodeError, ValueError):
        calls = []

        def fail(*args, error=error, calls=calls):
            calls.append(args)
            raise error("forced")
        kinds, texts, _, deg = with_tokenizer(fail, lambda: s.classify(text, "python"))
        fed = [list(iter(args[0], "")) for args in calls]
        problems += ["%s: %s" % (error.__name__, p) for p in equal(
            ([len(args) for args in calls], fed, kinds, texts, deg),
            ([1], [["x = 1\n", "# c\n"]], ["code", "comment"], {1: "c"}, True))]
    return problems


@check("classify: tokenize runs once for python and never for the other eight languages")
def tokenize_only_python():
    calls, original = [], s.tokenize.generate_tokens

    def spy(*args):
        calls.append(len(args))
        return original(*args)
    others = with_tokenizer(spy, lambda: [s.classify("x = 1\n", lang)[0] for lang in FUZZ_LANGS[1:]])
    after_others = list(calls)
    python = with_tokenizer(spy, lambda: s.classify("x = 1\n", "python")[0])
    return equal((after_others, others, calls, python), ([], [["code"]] * 8, [1], ["code"]))


REFERENCE = [("python", "x = 1  # c\n", "M"), ("sh", "echo hi # c\n", "M"), ("ruby", "x = 1 # c\n", "M"),
             ("js", "f(); // c\n", "M"), ("go", "x := 1 // c\n", "M"), ("php", "<?php $x = 1; // c\n", "M")]
POISON = [("python", 'x = """open\n'), ("sh", "cat <<EOF\n"), ("ruby", "=begin\n"), ("js", "x = `open\n"),
          ("jsx", "<div>\n"), ("ts", "/* open\n"), ("tsx", "<p>{\n"), ("go", "s := `open\n"),
          ("php", "<?php $s = 'open\n")]


def letters(lang, text):
    return "".join(LETTER[k] for k in s.classify(text, lang)[0])


def broken_run(cls):
    """Each REFERENCE outcome while `cls._step` raises (its letters, or the error text), and the language of
    every call the broken method received."""
    original, calls, current = cls._step, [], [None]

    def broken(self, row, line, i):
        calls.append((current[0], self.lang, row, i))
        raise RuntimeError("broken " + cls.__name__)
    cls._step = broken
    try:
        got = []
        for lang, text, _ in REFERENCE:
            current[0] = lang
            try:
                got.append(letters(lang, text))
            except RuntimeError as exc:
                got.append(str(exc))
        return got, calls
    finally:
        cls._step = original


@check("isolation: breaking the c-family scanner breaks js, go and php but leaves python, sh and ruby intact")
def isolate_c_family():
    return equal(broken_run(s._CScan), (["M", "M", "M", "broken _CScan", "broken _CScan", "broken _CScan"],
                                        [("js", "js", 0, 0), ("go", "go", 0, 0), ("php", "php", 0, 0)]))


@check("isolation: breaking the '#' scanner breaks sh and ruby but leaves tokenized python, js, go and php intact")
def isolate_hash_family():
    return equal(broken_run(s._HashScan), (["M", "broken _HashScan", "broken _HashScan", "M", "M", "M"],
                                           [("sh", "sh", 0, 0), ("ruby", "ruby", 0, 0)]))


@check("isolation: each scanner's step is called for its own languages only, from the first character on")
def step_contract():
    calls, originals = [], {cls: cls._step for cls in (s._CScan, s._HashScan)}

    def spying(cls):
        def step(self, row, line, i):
            calls.append((cls.__name__, self.lang))
            return originals[cls](self, row, line, i)
        return step
    for cls in originals:
        cls._step = spying(cls)
    try:
        got = [letters(lang, text) for lang, text, _ in REFERENCE]
    finally:
        for cls, step in originals.items():
            cls._step = step
    used = sorted(set(calls))
    return equal((got, used, calls.count(("_HashScan", "sh")) > 0),
                 (["M"] * 6, [("_CScan", "go"), ("_CScan", "js"), ("_CScan", "php"), ("_HashScan", "ruby"),
                              ("_HashScan", "sh")], True))


@check("isolation: a construct left open in one call, in any language, never reaches the next call")
def no_leak():
    before = [letters(lang, text) for lang, text, _ in REFERENCE]
    left_open = [s.classify(text, lang)[3] for lang, text in POISON]
    after = [letters(lang, text) for lang, text, _ in REFERENCE]
    return equal((left_open, before, after), ([True] * len(POISON), ["M"] * 6, ["M"] * 6))


def duplicate_defs(source):
    seen, dups = set(), []
    for node in ast.parse(source).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name in seen:
                dups.append(node.name)
            seen.add(node.name)
    return dups


def helper_files():
    files = sorted(glob.glob(os.path.join(sys.argv[1], "zuvo_comment_*.py")))
    cli = os.path.join(sys.argv[1], "comment-audit")
    return files + ([cli] if os.path.exists(cli) else [])


@check("guard: the duplicate-def scan covers zuvo_comment_scan.py")
def guard_covers():
    names = [os.path.basename(f) for f in helper_files()]
    return [] if "zuvo_comment_scan.py" in names else ["scanned %r" % names]


@check("guard: no top-level def or class is defined twice in the comment-audit helpers")
def guard_clean():
    found = []
    for path in helper_files():
        with open(path, encoding="utf-8") as handle:
            found += ["%s: %s" % (os.path.basename(path), d) for d in duplicate_defs(handle.read())]
    return found


@check("guard: the duplicate-def scan flags a fixture with two defs")
def guard_control():
    control = duplicate_defs("def f():\n    return 1\n\n\ndef f():\n    return 2\n")
    return [] if control == ["f"] else ["got %r" % control]


# The whole-prefix form the ruby lookback replaced: the oracle the bounded window must agree with.
OLD_RB_OPERAND = re.compile(
    r"(^|[(,=:\[!&|?{};+\-*%<>~^]|\b(if|unless|elsif|when|return|and|or|not|while|until|then|do))\s*$")
RB_BITS = ["if", "unless", "elsif", "when", "return", "and", "or", "not", "while", "until", "then", "do", "xif",
           "endif", "_do", "dox", "é", "数", "ß", "1", "a", " ", "\t", " ", " ", "\x1c", "/", "%", "(", ",",
           "=", ")", "]", ".", "?", "~", "^", "#", "'", '"', "\\"]


@check("ruby: the operand lookback answers as the whole-prefix regex did, at every index of 3000 seeded lines")
def operand_equivalence():
    rng = random.Random(20261003)
    for _ in range(3000):
        line = "".join(rng.choice(RB_BITS) for _ in range(rng.randint(0, 14)))
        for i in range(len(line) + 1):
            want = OLD_RB_OPERAND.search(line, 0, i) is not None
            if s._operand_due(line, i) != want:
                return ["%r at %d: got %r, want %r" % (line, i, not want, want)]
    return []


def operand_work(src):
    """Characters the ruby operand regex is handed while `src` is classified: its work, counted, not timed."""
    real, seen = s._RB_OPERAND, [0]

    class Counting:
        def search(self, string, pos=0, endpos=sys.maxsize):
            seen[0] += max(0, min(endpos, len(string)) - pos)
            return real.search(string, pos, endpos)
    s._RB_OPERAND = Counting()
    try:
        s.classify(src, "ruby")
    finally:
        s._RB_OPERAND = real
    return seen[0]


def growth(c1, c2, c3):
    """"linear" when the counts at k, 2k and 3k units grow by one fixed step, else "superlinear"."""
    steps = (c2 - c1, c3 - c2)
    return "linear" if steps[0] > 0 and abs(steps[1] - steps[0]) <= steps[0] // 100 else "superlinear"


@check("scaling: each ruby '/' or '%(' hands the operand regex a bounded window, so its work grows linearly with the line")
def operand_scaling():
    shapes = [("'/' after an operand", lambda k: "x = a" + " / b" * k + "\n"),
              ("'%(' after an operand", lambda k: "x = a" + " %(b) c" * k + "\n"),
              ("'/' after long blank runs", lambda k: "x = a" + (" " * 40 + "/ b") * k + "\n")]
    got = [(name, growth(*[operand_work(make(200 * m)) for m in (1, 2, 3)])) for name, make in shapes]
    return equal((got, growth(100, 400, 900)), ([(name, "linear") for name, _ in shapes], "superlinear"))


FRAGMENTS = ['"', "'", "`", "#", "//", "/*", "*/", "{", "}", "(", ")", "$(", "$((", "${", "#{", "<", ">", "/", "\\",
             "<<EOF", "EOF", "<<<", "<?php", "?>", "=begin", "=end", '"""', "'''", "\n", "\r\n", "\r", "\x0c", "\x00",
             "é", "ząb", " ", "\t", "x", "1", ";", "=", "noqa", "<div>", "</div>", "/>", "<>", "return"]


def fuzz(lang, seed):
    rng = random.Random(seed)
    for _ in range(FUZZ_INPUTS):
        text = (BOM if rng.random() < 0.05 else "") + "".join(rng.choice(FRAGMENTS) for _ in range(rng.randint(0, 40)))
        try:
            kinds, ctext, docs, _ = s.classify(text, lang)
        except Exception as exc:
            return ["seed %d input %r raised %r" % (seed, text, exc)]
        rows = {i for i, k in enumerate(kinds) if k in ("comment", "mixed")}
        if len(kinds) != len(s.split_lines(text)) or set(ctext) != rows or not docs <= rows:
            return ["seed %d input %r: %d kinds for %d lines, text rows %s, comment rows %s"
                    % (seed, text, len(kinds), len(s.split_lines(text)), sorted(ctext), sorted(rows))]
    return []


for index, fuzz_lang in enumerate(FUZZ_LANGS):
    CHECKS.append(("fuzz: %s — %d seeded inputs never raise or shift rows" % (fuzz_lang, FUZZ_INPUTS),
                   lambda lang=fuzz_lang, seed=20261002 + index: fuzz(lang, seed)))


def run_case(lang, src, want, texts, doc, degraded):
    kinds, ctext, docs, deg = s.classify(src, lang)
    got = "".join(LETTER.get(k, "?") for k in kinds)
    rows = {i for i, k in enumerate(kinds) if k in ("comment", "mixed")}
    got_all = (got, ctext, set(docs), (deg, type(deg)), sorted(ctext))
    want_all = (want, texts, set(doc), (degraded, bool), sorted(rows))
    names = ("kinds", "text", "doc", "degraded", "comment_text rows vs comment/mixed rows")
    return ["%s %r, want %r" % (n, g, w) for n, g, w in zip(names, got_all, want_all) if g != w]


def run_detect(triples):
    problems = []
    for path, first, want in triples:
        got = s.detect_language(path, first)
        if got != want:
            problems.append("%s %r -> %r, want %r" % (path, first, got, want))
    return problems


def report(name, run):
    try:
        problems = run()
    except Exception as exc:
        problems = ["raised %r" % exc]
    if not isinstance(problems, list):
        problems = ["returned %r instead of a list of problems" % (problems,)]
    print(("NO %s: %s" % (name, "; ".join(problems))) if problems else "OK " + name)
    return not problems


print("DECLARED %d" % (len(DETECTS) + len(CASES) + len(CHECKS)))
verdicts = [report(name, lambda triples=triples: run_detect(triples)) for name, triples in DETECTS]
verdicts += [report(name, lambda spec=spec: run_case(*spec)) for name, *spec in CASES]
verdicts += [report(name, fn) for name, fn in CHECKS]
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
if is_int "$declared" && is_int "$total" && [ "$declared" -ge 150 ] && [ "$seen" -eq "$total" ] \
  && [ "$total" -eq "$declared" ]; then
  pass "every declared case reported one verdict ($seen)"
else
  bad "verdicts $seen, TOTAL [$total], DECLARED [$declared] — they must be equal integers, DECLARED >= 150"
fi

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"
exit "$fail"
