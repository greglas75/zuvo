"""Per-line comment classification for comment-audit: which lines are code, comment or both."""
from __future__ import annotations

import io
import os
import re
import shlex
import tokenize
from typing import Callable

BLANK, CODE, COMMENT, MIXED = "blank", "code", "comment", "mixed"
UNSUPPORTED = "n/a"
POLYGLOT = "''''exec"
HEADER_LINES = 10

EXTENSIONS = {
    ".py": "python", ".sh": "sh", ".bash": "sh", ".zsh": "sh", ".bats": "sh", ".rb": "ruby", ".rake": "ruby",
    ".js": "js", ".mjs": "js", ".cjs": "js", ".jsx": "jsx", ".ts": "ts", ".mts": "ts", ".cts": "ts",
    ".tsx": "tsx", ".go": "go", ".php": "php",
}
LANGUAGES = frozenset(EXTENSIONS.values())
SHELLS = frozenset({"sh", "bash", "zsh", "dash", "ksh", "bats"})

_DIRECTIVES = (
    r"@ts-(expect-error|ignore|nocheck)|eslint-(disable|enable)|prettier-ignore|istanbul ignore|c8 ignore"
    r"|@(vitest|jest)-environment|<reference\b|go:(build|generate)\b|nolint\b|noqa\b|type:\s*ignore\b"
    r"|pragma:\s*no cover|shellcheck\s+[a-z-]+=|-\*-\s*coding|fmt:\s*(off|on)\b|@phpstan-|@psalm-"
)
# A directive changes what a compiler, linter or test runner does, so a directive-only comment is code. It
# counts at the start of the comment or after an inner marker; prose before it is still audited as comment.
PRAGMA = re.compile(r"(^|#|//)[\s*/!]*(" + _DIRECTIVES + ")", re.IGNORECASE)

_SQ, _SQE, _DQ, _BT, _TSQ, _TDQ, _TPL, _RAW = "sq", "sqe", "dq", "bt", "tsq", "tdq", "tpl", "raw"
_ARITH, _INTERP, _EXPR, _BLOCK, _REGEX = "arith", "interp", "expr", "block", "regex"
_TAG, _TEXT, _HTML, _PHP, _LIT = "tag", "text", "html", "php", "lit"
_CLOSER = {_SQ: "'", _SQE: "'", _DQ: '"', _BT: "`", _RAW: "`", _TSQ: "'''", _TDQ: '"""'}
_STRINGS = frozenset(_CLOSER) | {_TPL, _LIT}
_RESTING = frozenset({_HTML, _PHP})
_OPENER_KIND = {"'": _SQ, '"': _DQ, "/": _REGEX}
_DQ_EXPANSIONS: dict[str, tuple[tuple[str, str], ...]] = {
    "sh": (("$((", _ARITH), ("$(", _INTERP)), "ruby": (("#{", _INTERP),)}
_SH_OPENERS = (("$'", _SQE), ("$((", _ARITH), ("$(", _INTERP))
_ARITH_COMMAND = (("((", _ARITH),)

_JS = frozenset({"js", "jsx", "ts", "tsx"})
_JSX = frozenset({"js", "jsx", "tsx"})
_WORD = re.compile(r"[A-Za-z_$][\w$]*|\d[\w.]*")
_TAG_START = re.compile(r"<[A-Za-z>]")
_TYPE_PARAMS = re.compile(r"<\s*[A-Za-z_$][\w$]*\s*(,|extends\b)")
_PHP_OPEN = re.compile(r"<\?(php\b|=)?")
_EXPR_CHARS = frozenset("(,=:[!&|?{};+-*%<>~^")
_EXPR_WORDS = frozenset({"return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
                         "case", "do", "else", "yield", "await"})
_SH_HEREDOC = re.compile(r"<<(?P<flag>-?)[ \t]*\\?(['\"]?)(?P<word>[A-Za-z_]\w*)\2")
_RB_HEREDOC = re.compile(r"<<(?P<flag>[~-]?)(['\"]?)(?P<word>[A-Za-z_]\w*)\2")
_PHP_HEREDOC = re.compile(r"<<<[ \t]*(['\"]?)(?P<word>[A-Za-z_]\w*)\1")
_HEREDOC_MODE = {("sh", "-"): "tabs", ("ruby", "-"): "strip", ("ruby", "~"): "strip"}
_RB_DOC = re.compile(r"=(begin|end)(\s|$)")
_RB_PERCENT = re.compile(r"%[qQwWiIrsx]?([^\w\s])")
_RB_KEYWORDS = ("if", "unless", "elsif", "when", "return", "and", "or", "not", "while", "until", "then", "do")
_RB_OPERAND = re.compile(r"(^|[(,=:\[!&|?{};+\-*%<>~^]|\b(" + "|".join(_RB_KEYWORDS) + r"))\s*$")
_RB_REACH = max(map(len, _RB_KEYWORDS))
_PAIRS = {"(": ")", "[": "]", "{": "}", "<": ">"}
_ENV_TAKES_ARG = frozenset({"-u", "-C", "-P", "--unset", "--chdir"})
_OPEN_QUOTE = re.compile(r"^[A-Za-z]*('''|\"\"\"|'|\")")
_CLOSE_QUOTE = re.compile(r"('''|\"\"\"|'|\")$")
_PY_SKIP = frozenset({tokenize.NL, tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER})
_KIND = {(True, True): MIXED, (True, False): CODE, (False, True): COMMENT}


def split_lines(text: str) -> list[str]:
    """Lines as git counts them: split on LF only, a trailing CR dropped."""
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return [line[:-1] if line.endswith("\r") else line for line in lines]


def detect_language(path: str, first_lines: list[str]) -> str:
    """Scanner key for `path`, or "n/a" when comment-audit does not scan that kind of file."""
    ext = os.path.splitext(path)[1].lower()
    if ext:
        return EXTENSIONS.get(ext, UNSUPPORTED)
    head = [line.rstrip("\r") for line in first_lines[:HEADER_LINES]]
    if head:
        head[0] = head[0].lstrip("\ufeff")
    if any(line.startswith(POLYGLOT) for line in head):
        return "python"
    words = _words(head[0][2:]) if head and head[0].startswith("#!") else []
    name = os.path.basename(words[0]) if words else ""
    if name == "env":
        name = os.path.basename(_env_target(words[1:]))
    for interpreter in ("python", "ruby"):
        if name.startswith(interpreter):
            return interpreter
    return "sh" if name in SHELLS else UNSUPPORTED


def _words(text: str) -> list[str]:
    try:
        return shlex.split(text)
    except ValueError:
        return text.split()


def _env_target(words: list[str]) -> str:
    """The command env runs: options, their arguments and NAME=value skipped; -S splits its string."""
    while words:
        word, words = words[0], words[1:]
        if word.startswith("-S"):
            words = _words(" ".join([word[2:], *words]))
        elif word in _ENV_TAKES_ARG:
            words = words[1:]
        elif not word.startswith("-") and "=" not in word:
            return word
    return ""


class _Lines:
    """Per-line code flag, comment flag and comment text, filled by a scanner."""

    def __init__(self, count: int) -> None:
        self.code = [False] * count
        self.note = [False] * count
        self.text: list[list[str]] = [[] for _ in range(count)]
        self.doc: set[int] = set()

    def comment(self, row: int, body: str) -> None:
        pragma = PRAGMA.search(body)
        prose = (body[:pragma.start()] if pragma else body).strip().lstrip("#*/!").strip()
        if pragma and not re.search(r"\w", prose):
            self.code[row] = True
            return
        self.note[row] = True
        self.text[row].append(prose)

    def docline(self, row: int, text: str) -> None:
        self.doc.add(row)
        self.note[row] = True
        self.text[row].append(text.strip())

    def result(self, lines: list[str], degraded: bool) -> tuple[list[str], dict[int, str], set[int], bool]:
        kinds = [_KIND.get((self.code[row], self.note[row]), CODE if line.strip() else BLANK)
                 for row, line in enumerate(lines)]
        texts = {row: " ".join(seg for seg in self.text[row] if seg)
                 for row in range(len(lines)) if self.note[row]}
        return kinds, texts, set(self.doc), degraded


def _python_tokens(lines: list[str]) -> list[tokenize.TokenInfo]:
    # A lone CR stays inside its git line; tokenize glues it to the next token (hiding a comment) or, before a
    # non-ASCII letter, raises UnicodeDecodeError.
    source = "".join(line.replace("\r", " ") + "\n" for line in lines)
    return list(tokenize.generate_tokens(io.StringIO(source).readline))


def _python(lines: list[str], tokens: list[tokenize.TokenInfo]) -> _Lines:
    acc = _Lines(len(lines))
    statement: list[tokenize.TokenInfo] = []
    for tok in tokens:
        if tok.type == tokenize.COMMENT:
            row = tok.start[0] - 1
            if row == 0 and tok.string.startswith("#!"):
                acc.code[row] = True
            else:
                acc.comment(row, tok.string[1:])
        elif tok.type == tokenize.NEWLINE:
            _python_statement(acc, statement, lines)
            statement = []
        elif tok.type not in _PY_SKIP:
            statement.append(tok)
    _python_statement(acc, statement, lines)
    return acc


def _python_statement(acc: _Lines, tokens: list[tokenize.TokenInfo], lines: list[str]) -> None:
    """A statement made only of string literals is documentation; any other token is code."""
    is_doc = (bool(tokens) and all(t.type == tokenize.STRING for t in tokens)
              and not lines[tokens[0].start[0] - 1].startswith(POLYGLOT))
    for tok in tokens:
        first = tok.start[0] - 1
        if not is_doc:
            for row in range(first, tok.end[0]):
                acc.code[row] = True
            continue
        pieces = tok.string.split("\n")
        pieces[0] = _OPEN_QUOTE.sub("", pieces[0])
        pieces[-1] = _CLOSE_QUOTE.sub("", pieces[-1])
        for offset, piece in enumerate(pieces):
            acc.docline(first + offset, piece)


def _closes(line: str, word: str, mode: str) -> bool:
    if mode == "php":
        return re.match(re.escape(word) + r"(?!\w)", line.lstrip()) is not None
    return {"tabs": line.lstrip("\t"), "strip": line.strip()}.get(mode, line) == word


def _word_start(line: str, i: int) -> bool:
    return i == 0 or line[i - 1] in " \t;|&()"


def _operand_due(line: str, i: int) -> bool:
    """Ruby: an operand is due at `i` after an operator, an opener, a keyword or nothing. Only the token
    before the blanks decides, so the regex reads a keyword's width, not the whole prefix."""
    end = i
    while end and line[end - 1].isspace():
        end -= 1
    return _RB_OPERAND.search(line, max(0, end - _RB_REACH), end) is not None


class _Frame:
    """An open construct (string, expansion, comment, JSX element) and its nesting depth."""

    __slots__ = ("kind", "depth", "delims")

    def __init__(self, kind: str, depth: int = 0, delims: str = "") -> None:
        self.kind, self.depth, self.delims = kind, depth, delims


class _Scan:
    """Line loop shared by the character scanners: open frames and pending heredoc bodies."""

    def __init__(self, lines: list[str], lang: str) -> None:
        self.lines, self.lang = lines, lang
        self.acc = _Lines(len(lines))
        self.stack: list[_Frame] = []
        self.bodies: list[tuple[str, str]] = []
        self.opened: list[tuple[str, str]] = []
        self.degraded = self.in_doc = False

    def run(self) -> tuple[_Lines, bool]:
        for row, line in enumerate(self.lines):
            if self.bodies:
                self.acc.code[row] = True
                if _closes(line, *self.bodies[0]):
                    self.bodies.pop(0)
            elif row == 0 and line.startswith("#!"):
                self.acc.code[row] = True
            elif not self._whole_line(row, line):
                self._scan(row, line)
            self.bodies.extend(self.opened)
            self.opened.clear()
        unclosed = [f for f in self.stack if f.kind not in _RESTING]
        return self.acc, self.degraded or self.in_doc or bool(self.bodies or unclosed)

    def _scan(self, row: int, line: str) -> None:
        top = self.top()
        if top in _STRINGS:
            self.acc.code[row] = True
        elif top == _BLOCK and not line.strip():
            # A blank row inside /* */ belongs to the comment block rather than splitting it in two.
            self.acc.comment(row, "")
        i = 0
        while i < len(line):
            i = self._step(row, line, i)
        self._line_end(line)

    def top(self) -> str:
        return self.stack[-1].kind if self.stack else ""

    def _push(self, kind: str, at: int, depth: int = 0) -> int:
        self.stack.append(_Frame(kind, depth))
        return at

    def _expansion(self, line: str, i: int, openers: tuple[tuple[str, str], ...]) -> int | None:
        for opener, kind in openers:
            if line.startswith(opener, i):
                return self._push(kind, i + len(opener), opener.count("(") + opener.count("{"))
        return None

    def _heredoc(self, line: str, i: int, pattern: re.Pattern[str]) -> int | None:
        # The second "<" of a "<<<" here-string is not a heredoc operator.
        m = None if i > 0 and line[i - 1] == "<" else pattern.match(line, i)
        if m is None: return None
        mode = "php" if self.lang == "php" else _HEREDOC_MODE.get((self.lang, m.group("flag")), "exact")
        self.opened.append((m.group("word"), mode))
        return m.end()

    def _step(self, row: int, line: str, i: int) -> int:
        raise NotImplementedError

    def _whole_line(self, row: int, line: str) -> bool:
        return False

    def _line_end(self, line: str) -> None:
        return None


class _HashScan(_Scan):
    """sh, ruby and the python fallback: '#' comments, quotes, expansions and heredocs."""

    def _whole_line(self, row: int, line: str) -> bool:
        edge = _RB_DOC.match(line)
        ruby_doc = self.in_doc or (edge is not None and edge.group(1) == "begin")
        if self.lang != "ruby" or self.stack or not ruby_doc:
            return False
        self.acc.comment(row, "" if edge else line)
        self.in_doc = edge is None or edge.group(1) == "begin"
        return True

    def _line_end(self, line: str) -> None:
        if self.lang == "python" and self.top() in (_SQE, _DQ):
            self.stack.pop()

    def _step(self, row: int, line: str, i: int) -> int:
        kind = self.top()
        if kind == _DQ:
            return self._dq(line, i)
        if kind == _LIT:
            return self._literal(line, i)
        if kind not in _CLOSER:
            return self._code(row, line, i)
        if line[i] == "\\" and kind != _SQ: return i + 2
        if not line.startswith(_CLOSER[kind], i): return i + 1
        self.stack.pop()
        return i + len(_CLOSER[kind])

    def _dq(self, line: str, i: int) -> int:
        if line[i] == "\\": return i + 2
        if line[i] == '"':
            self.stack.pop()
            return i + 1
        opened = self._expansion(line, i, _DQ_EXPANSIONS.get(self.lang, ()))
        return i + 1 if opened is None else opened

    def _code(self, row: int, line: str, i: int) -> int:
        c = line[i]
        if c in " \t": return i + 1
        in_arith = self.top() == _ARITH
        word_start = self.lang == "python" or _word_start(line, i)
        if c == "#" and word_start and not in_arith:
            self.acc.comment(row, line[i + 1:])
            return len(line)
        self.acc.code[row] = True
        if c == "\\": return i + 2
        opened = self._open(line, i, in_arith)
        if opened is not None: return opened
        if self.stack: self._nest(c)
        return i + 1

    def _open(self, line: str, i: int, in_arith: bool) -> int | None:
        c = line[i]
        if self.lang == "python" and line.startswith(("'''", '"""'), i):
            kind = _TSQ if c == "'" else _TDQ
            return self._push(kind, i + len(_CLOSER[kind]))
        if c == "'": return self._push(_SQ if self.lang == "sh" else _SQE, i + 1)
        if c == '"': return self._push(_DQ, i + 1)
        if c == "`" and self.lang != "python": return self._push(_BT, i + 1)
        if self.lang == "ruby": return self._ruby_open(line, i)
        if self.lang != "sh": return None
        opened = self._expansion(line, i, _SH_OPENERS)
        if opened is None and _word_start(line, i):
            opened = self._expansion(line, i, _ARITH_COMMAND)
        if opened is None and not in_arith and line.startswith("<<", i):
            opened = self._heredoc(line, i, _SH_HEREDOC)
        return opened

    def _ruby_open(self, line: str, i: int) -> int | None:
        # "<<" right after a name, ")" or "]" appends; "%" and "/" open a literal only where an operand is due
        appends = i > 0 and (line[i - 1].isalnum() or line[i - 1] in "_)]")
        if line.startswith("<<", i):
            return None if appends else self._heredoc(line, i, _RB_HEREDOC)
        percent = _RB_PERCENT.match(line, i)
        delim = "/" if line[i] == "/" else percent.group(1) if percent else ""
        if not delim or not _operand_due(line, i): return None
        self.stack.append(_Frame(_LIT, 1, delim + _PAIRS.get(delim, delim)))
        return percent.end() if percent else i + 1

    def _literal(self, line: str, i: int) -> int:
        top, c = self.stack[-1], line[i]
        if c == "\\": return i + 2
        opener, closer = top.delims[0], top.delims[-1]
        top.depth += (c == opener != closer) - (c == closer)
        if top.depth <= 0: self.stack.pop()
        return i + 1

    def _nest(self, c: str) -> None:
        top = self.stack[-1]
        opener, closer = ("{", "}") if self.lang == "ruby" else ("(", ")")
        top.depth += (c == opener) - (c == closer)
        if top.depth <= 0:
            self.stack.pop()


class _CScan(_Scan):
    """c-family: strings, templates, raw strings, regex literals, JSX text and PHP sections."""

    def __init__(self, lines: list[str], lang: str) -> None:
        super().__init__(lines, lang)
        self.prev = ""
        self.handlers: dict[str, Callable[[int, str, int], int]] = {
            "": self._code, _EXPR: self._code, _PHP: self._code, _SQ: self._string, _DQ: self._string,
            _RAW: self._string, _TPL: self._template, _BLOCK: self._block, _REGEX: self._regex,
            _TAG: self._tag, _TEXT: self._text, _HTML: self._html,
        }
        if lang == "php":
            self.stack.append(_Frame(_HTML))

    def _step(self, row: int, line: str, i: int) -> int:
        return self.handlers[self.top()](row, line, i)

    def _line_end(self, line: str) -> None:
        # Only PHP strings span lines; an open quote or regex here is malformed, so it is closed (and the
        # file marked degraded) instead of turning every later row into string.
        continues = self.lang == "php" or line.endswith("\\")
        if self.top() == _REGEX or (self.top() in (_SQ, _DQ) and not continues):
            self.degraded = True
            self._close()

    def _close(self) -> None:
        self.stack.pop()
        self.prev = "x"

    def _code(self, row: int, line: str, i: int) -> int:
        c = line[i]
        if c in " \t": return i + 1
        php_hash = c == "#" and self.lang == "php" and not line.startswith("#[", i)
        if php_hash or line.startswith("//", i):
            return self._line_comment(row, line, i + (1 if php_hash else 2))
        if line.startswith("/*", i):
            self.stack.append(_Frame(_BLOCK))
            return self._block(row, line, i + 2)
        self.acc.code[row] = True
        word = _WORD.match(line, i)
        if word:
            self.prev = word.group()
            return word.end()
        opened = self._open(line, i)
        if opened is not None: return opened
        self._brace(c)
        self.prev = c
        return i + 1

    def _line_comment(self, row: int, line: str, start: int) -> int:
        return self._comment_to(row, line, start, line.find("?>", start) if self.lang == "php" else -1)

    def _comment_to(self, row: int, line: str, start: int, end: int) -> int:
        """Comment text from `start` to `end`, a two-character closer that pops the top frame, or to the
        line end when `end` is -1."""
        self.acc.comment(row, line[start:] if end < 0 else line[start:end])
        if end < 0: return len(line)
        self.stack.pop()
        return end + 2

    def _push(self, kind: str, at: int, depth: int = 0) -> int:
        if kind in (_EXPR, _TAG):
            self.prev = ""  # ${...}, {...} and a tag start a fresh expression, so "/" there opens a regex
        return super()._push(kind, at, depth)

    def _expects_operand(self) -> bool:
        # "/" or "<" opens a regex or JSX tag only where an operand is due; after a name it is an operator.
        return not self.prev or self.prev in _EXPR_CHARS or self.prev in _EXPR_WORDS

    def _open(self, line: str, i: int) -> int | None:
        c = line[i]
        operand = self.lang in _JS and self._expects_operand()
        if c in "'\"`" or (c == "/" and operand):
            self.prev = "x"
            return self._push(_OPENER_KIND.get(c, _TPL if self.lang in _JS else _RAW), i + 1)
        jsx_tag = operand and self.lang in _JSX and _TAG_START.match(line, i) is not None
        if jsx_tag and not _TYPE_PARAMS.match(line, i): return self._push(_TAG, i + 1)
        if self.lang != "php": return None
        if line.startswith("?>", i):
            self.stack.pop()
            return i + len("?>")
        return self._heredoc(line, i, _PHP_HEREDOC) if line.startswith("<<<", i) else None

    def _brace(self, c: str) -> None:
        if self.top() != _EXPR or c not in "{}": return
        top = self.stack[-1]
        top.depth += 1 if c == "{" else -1
        if top.depth < 0: self.stack.pop()

    def _string(self, row: int, line: str, i: int) -> int:
        kind = self.top()
        if line[i] == "\\" and kind != _RAW: return i + 2
        if line[i] == _CLOSER[kind]: self._close()
        return i + 1

    def _template(self, row: int, line: str, i: int) -> int:
        if line[i] == "\\": return i + 2
        if line[i] == "`": self._close()
        if line.startswith("${", i): return self._push(_EXPR, i + 2)
        return i + 1

    def _block(self, row: int, line: str, i: int) -> int:
        return self._comment_to(row, line, i, line.find("*/", i))

    def _regex(self, row: int, line: str, i: int) -> int:
        c = line[i]
        if c == "\\": return i + 2
        if c in "[]": self.stack[-1].depth = int(c == "[")
        elif c == "/" and not self.stack[-1].depth: self._close()
        return i + 1

    def _tag(self, row: int, line: str, i: int) -> int:
        c = line[i]
        self.acc.code[row] = self.acc.code[row] or not c.isspace()
        if c in "'\"{": return self._push(_OPENER_KIND.get(c, _EXPR), i + 1)
        if line.startswith("/>", i):
            self._close()
            return i + 2
        if c == ">": self.stack[-1].kind = _TEXT
        return i + 1

    def _text(self, row: int, line: str, i: int) -> int:
        self.acc.code[row] = self.acc.code[row] or not line[i].isspace()
        if line[i] == "{": return self._push(_EXPR, i + 1)
        if line.startswith("</", i):
            self._close()
            end = line.find(">", i)
            self.degraded = self.degraded or end < 0
            return len(line) if end < 0 else end + 1
        return self._push(_TAG, i + 1) if _TAG_START.match(line, i) else i + 1

    def _html(self, row: int, line: str, i: int) -> int:
        self.acc.code[row] = self.acc.code[row] or not line[i].isspace()
        opener = _PHP_OPEN.match(line, i)
        return self._push(_PHP, opener.end()) if opener else i + 1


def classify(text: str, lang: str) -> tuple[list[str], dict[int, str], set[int], bool]:
    """Kind of each `split_lines(text)` row (0-based), comment text of comment and mixed rows,
    python docstring rows, and whether the scan is unreliable (tokenize fallback or an unclosed construct)."""
    if lang not in LANGUAGES:
        raise ValueError(f"unsupported language: {lang!r}")
    lines = split_lines(text)
    if lines and lines[0].startswith("\ufeff"):
        lines[0] = lines[0][1:]
    if lang == "python":
        # Any repo text reaches tokenize; NUL after an indent raises SystemError, so every failure falls back.
        try:
            tokens = _python_tokens(lines)
        except (tokenize.TokenError, SyntaxError, SystemError, UnicodeError, ValueError):
            acc, _ = _HashScan(lines, "python").run()
            return acc.result(lines, True)
        return _python(lines, tokens).result(lines, False)
    scanner = _HashScan(lines, lang) if lang in ("sh", "ruby") else _CScan(lines, lang)
    acc, degraded = scanner.run()
    return acc.result(lines, degraded)
