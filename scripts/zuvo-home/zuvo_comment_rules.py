"""Rules comment-audit applies to the comment lines a change authored: density, narration, long blocks."""
from __future__ import annotations

import bisect
import hashlib
import itertools
import re
from collections import Counter
from dataclasses import dataclass
from typing import AbstractSet, Callable, Iterable, Mapping, NamedTuple, Tuple

import zuvo_comment_scan as scan

CODE_KINDS = frozenset({scan.CODE, scan.MIXED})
REASON_MIN, HASH_WIDTH, INCIDENT_SPAN = 20, 8, 300
ORACLE_PREFIXES = ("Oracle:", "dual-oracle")
DUPLICATE, SHORT, OVER_CAP = "duplicate", "short", "over-cap"
HINTS = {"D": "delete comments that restate the code",
         "N": "move the history to the commit message or a runbook; keep only the current constraint",
         "L": "cut to the WHY, or delete it if it restates the code"}


@dataclass(frozen=True)
class ThresholdSpec:
    name: str
    env: str
    default: float
    integer: bool
    valid: str
    accepts: Callable[[float], bool]


THRESHOLD_SPECS = (
    ThresholdSpec("density", "ZUVO_COMMENT_MAX_DENSITY", 0.30, False, "0 < x <= 1", lambda x: 0 < x <= 1),
    ThresholdSpec("min_lines", "ZUVO_COMMENT_MIN_LINES", 20, True, "integer >= 1", lambda x: x >= 1),
    ThresholdSpec("block", "ZUVO_COMMENT_BLOCK_MIN", 4, True, "integer >= 2", lambda x: x >= 2),
    ThresholdSpec("justify_max", "ZUVO_COMMENT_JUSTIFY_MAX", 2, True, "integer >= 0", lambda x: x >= 0),
)

_MONTHS = ("january|february|march|april|may|june|july|august|september|october|november|december"
           "|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec")
_DATE = (r"\b(19|20)\d\d-(0[1-9]|1[0-2])(-(0[1-9]|[12]\d|3[01]))?\b(?!-\d)"
         r"|\b(" + _MONTHS + r")\.?\s+(19|20)\d\d\b")
_ID_LIKE = r"(?-i:\b[A-Z]+-\d+\b)|(?<!\w)#\d+\b"
NARRATIVE = (
    ("N-date", _DATE),
    ("N-history", r"\b(previously|formerly|originally|used\s+to|until\s+recently|at\s+the\s+time|back\s+then"
                  r"|historically|we\s+(changed|switched|moved|replaced|removed)"
                  r"|was\s+(changed|replaced|removed|introduced)|(changed|switched|migrated)\s+from"
                  r"|in\s+the\s+(old|previous)\s+(version|code|implementation))\b"),
    ("N-incident", r"\b(post-?mortem|hotfix|field\s+(run|failure|report|data))\b"
                   r"|\b(incident|outage)s?\b.{0,%d}?(" % INCIDENT_SPAN + _DATE + "|" + _ID_LIKE + ")"),
    ("N-measured", r"\b(measured\s+(on|at|over|across|by)|benchmark(ed)?\s+(showed|shows|on)"
                   r"|we\s+(saw|observed|measured)|turned\s+out|it\s+turns\s+out|empirically)\b"),
    ("N-pl", r"\b(wcześniej\b|poprzednio\b|incydent\w*|zmierzon\w*\b(?!\s+w\s+<path>))"),
)
CLAIM_PATTERNS = (
    ("number-unit", r"\b\d+(\.\d+)?\s?(ms|s|sec|seconds?|min|minutes?|h|hours?|KB|MB|GB"
                    r"|retries|attempts|times)\b"),
    ("percent", r"\b\d+(\.\d+)?\s?%"),
    ("bound", r"\b(within|at\s+most|at\s+least|up\s+to)\s+\d"),
    ("guarantee", r"\bguarantee[sd]?\b"),
)
_NARRATIVE_RE = [(family, re.compile(p, re.IGNORECASE | re.DOTALL)) for family, p in NARRATIVE]
_CLAIM_RE = [re.compile(p, re.IGNORECASE) for _, p in CLAIM_PATTERNS]
_PATHLIKE = re.compile(r"(?<!\S)\S*/\S*")
_LITERAL = re.compile(r"`[^`]*`|(?<!\w)(\"[^\"]*\"|'[^']*')(?!\w)")
_WORD = re.compile(r"\w")
_PRELUDE = re.compile(r"#!|''''exec|<\?php\b|package\s+[\w.]+;?\s*$")
_MODIFIERS = r"((export|default|async|public|private|protected|static|abstract|final|override)\s+)*"
SIGNATURE = re.compile(r"\s*" + _MODIFIERS + r"(def\s+[A-Za-z_]\w*|class\s+[A-Za-z_$][\w$]*"
                       r"|function(\s+|\s*\*\s*)[A-Za-z_$][\w$]*|func\s+(\([^)]*\)\s*)?[A-Za-z_]\w*)")
_HASHED_ID = re.compile(r"[NL]:.+?:[0-9a-f]{%d}=" % HASH_WIDTH, re.DOTALL)
_FLATTEN = re.compile(r"[\t\r\n|]")


Threshold = NamedTuple("Threshold", [("name", str), ("env", str), ("value", float), ("source", str)])
Block = NamedTuple("Block", [("start", int), ("end", int), ("words", Tuple[int, ...])])
Finding = NamedTuple("Finding", [("id", str), ("rule", str), ("sub", str), ("line", int), ("text", str),
                                 ("hint", str)])
Claim = NamedTuple("Claim", [("line", int), ("text", str)])
Rejection = NamedTuple("Rejection", [("id", str), ("kind", str), ("why", str)])


@dataclass(frozen=True)
class FileView:
    path: str
    lang: str
    text: str
    added: AbstractSet[int]
    carried: AbstractSet[int]


@dataclass
class FileResult:
    path: str
    lang: str
    authored_code: int
    authored_comment: int
    carried: int
    density: float | None
    file_density: float | None
    degraded: bool
    findings: list[Finding]
    claims: list[Claim]


@dataclass
class Justification:
    accepted: dict[str, str]
    rejected: list[Rejection]
    stale: list[str]


@dataclass
class _Context:
    path: str
    lines: list[str]
    kinds: list[str]
    texts: dict[int, str]
    doc: set[int]
    authored: set[int]


def load_thresholds(environ: Mapping[str, str]) -> dict[str, Threshold]:
    """Thresholds by name. Only an empty string is unset; a whitespace-only, unparsable or out-of-range value
    raises ValueError naming the variable."""
    return {spec.name: _threshold(spec, environ.get(spec.env, "")) for spec in THRESHOLD_SPECS}


def _threshold(spec: ThresholdSpec, raw: str) -> Threshold:
    if raw == "": return Threshold(spec.name, spec.env, spec.default, "default")
    text = raw.strip()
    shape = r"\d+" if spec.integer else r"\d+(\.\d*)?|\.\d+"
    try:
        value = (int(text) if spec.integer else float(text)) if re.fullmatch(shape, text, re.ASCII) else None
    except ValueError:
        value = None
    if value is None or not spec.accepts(value):
        raise ValueError(f"{spec.env}={raw!r} is invalid: expected {spec.valid}")
    return Threshold(spec.name, spec.env, value, "env")


def format_threshold(value: float) -> str:
    if isinstance(value, int): return str(value)
    fixed = f"{value:.2f}"
    return fixed if float(fixed) == value else repr(value)


def describe_thresholds(thresholds: Mapping[str, Threshold]) -> str:
    """The `thresholds:` line: every value with its source."""
    return " ".join(f"{t.name}={format_threshold(t.value)}({t.source})" for t in thresholds.values())


def env_overrides(thresholds: Mapping[str, Threshold]) -> list[str]:
    """Variables that set a threshold, for the `env=` field of both machine lines."""
    return [t.env for t in thresholds.values() if t.source == "env"]


def carried_lines(added_by_file: Mapping[str, Mapping[int, str]],
                  removed_all: Iterable[str]) -> dict[str, set[int]]:
    """Added rows matched one-to-one with removed lines of the whole diff, whitespace-normalized.
    Paths are visited in sorted order and rows in row order, so input order never changes the result."""
    pool = Counter(key for key in (" ".join(line.split()) for line in removed_all) if key)
    carried: dict[str, set[int]] = {}
    for path in sorted(added_by_file):
        rows = added_by_file[path]
        carried[path] = set()
        for row in sorted(rows):
            key = " ".join(rows[row].split())
            if key and pool[key] > 0:
                pool[key] -= 1
                carried[path].add(row)
    return carried


def blocks(kinds: list[str], comment_text: Mapping[int, str]) -> list[Block]:
    """Maximal runs of comment-only rows, each with the rows that hold a word character."""
    found = []
    for is_comment, group in itertools.groupby(range(len(kinds)), key=lambda row: kinds[row] == scan.COMMENT):
        rows = list(group)
        if is_comment: found.append(Block(rows[0], rows[-1] + 1, _words(rows, comment_text)))
    return found


def _words(rows: Iterable[int], comment_text: Mapping[int, str]) -> tuple[int, ...]:
    return tuple(row for row in rows if _WORD.search(comment_text.get(row, "")))


def evaluate(view: FileView, thresholds: Mapping[str, Threshold]) -> FileResult:
    """Counts, findings and claims for one file; ValueError when the scanner does not know `view.lang`."""
    kinds, texts, doc, degraded = scan.classify(view.text, view.lang)
    rows = range(len(kinds))
    authored = {row for row in view.added if row in rows and row not in view.carried}
    lines = scan.split_lines(view.text)
    if len(lines) != len(kinds): raise ValueError(f"{view.path}: {len(kinds)} rows for {len(lines)} lines")
    if lines and lines[0].startswith("\ufeff"): lines[0] = lines[0][1:]
    ctx = _Context(view.path, lines, kinds, texts, doc, authored)
    comments, code = _comment_rows(ctx, sorted(authored)), _code_count(ctx, authored)
    file_comments = len(_comment_rows(ctx, rows))
    total, file_total = len(comments) + code, file_comments + _code_count(ctx, rows)
    density = len(comments) / total if total >= thresholds["min_lines"].value else None
    findings = _density_finding(ctx, comments, total, density, thresholds["density"].value)
    findings += _block_findings(ctx, thresholds["block"].value)
    carried = sum(1 for row in view.added if row in rows and row in view.carried)
    return FileResult(view.path, view.lang, code, len(comments), carried, density,
                      file_comments / file_total if file_total else None, degraded, findings, _claims(ctx))


def _comment_rows(ctx: _Context, rows: Iterable[int]) -> list[int]:
    return [row for row in rows if ctx.kinds[row] == scan.COMMENT and _WORD.search(ctx.texts.get(row, ""))]


def _code_count(ctx: _Context, rows: Iterable[int]) -> int:
    return sum(1 for row in rows if ctx.kinds[row] in CODE_KINDS)


def _density_finding(ctx: _Context, comments: list[int], total: int, density: float | None,
                     limit: float) -> list[Finding]:
    if density is None or density <= limit: return []
    text = f"{len(comments)} of {total} authored lines are comments"
    sub = f"{density:.3f}>{format_threshold(limit)}"
    return [Finding(finding_id("D", ctx.path, ""), "D", sub, comments[0] + 1, text, HINTS["D"])]


def _block_findings(ctx: _Context, block_min: float) -> list[Finding]:
    header = _header_row(ctx)
    seen: Counter[str] = Counter()
    findings = []
    for unit in _units(ctx):
        text = "\n".join(ctx.texts[row] for row in unit.words)
        hits = [_narrative(ctx, unit), None if unit.start == header else _long(ctx, unit, block_min)]
        for rule, sub, row in filter(None, hits):
            seen[rule + text] += 1
            ident = finding_id(rule, ctx.path, text, seen[rule + text])
            findings.append(Finding(ident, rule, sub, row + 1, ctx.texts[row], HINTS[rule]))
    return findings


def _units(ctx: _Context) -> list[Block]:
    trailing = [Block(row, row + 1, _words([row], ctx.texts)) for row, kind in enumerate(ctx.kinds)
                if kind == scan.MIXED]
    return sorted(blocks(ctx.kinds, ctx.texts) + trailing, key=lambda unit: unit.start)


def _header_row(ctx: _Context) -> int | None:
    for row, kind in enumerate(ctx.kinds):
        if kind == scan.COMMENT: return row
        if kind != scan.BLANK and not _PRELUDE.match(ctx.lines[row]): return None
    return None


def _narrative(ctx: _Context, unit: Block) -> tuple[str, str, int] | None:
    rows = [row for row in unit.words if row in ctx.authored]
    pieces = [_LITERAL.sub(" ", _PATHLIKE.sub("<path>", ctx.texts[row])) for row in rows]
    joined = "\n".join(pieces)
    ends = list(itertools.accumulate(len(piece) + 1 for piece in pieces))
    for family, pattern in _NARRATIVE_RE:
        match = pattern.search(joined)
        if match: return "N", family, rows[bisect.bisect_right(ends, match.start())]
    return None


def _long(ctx: _Context, block: Block, block_min: float) -> tuple[str, str, int] | None:
    size = len(block.words)
    authored = sum(1 for row in block.words if row in ctx.authored)
    is_block = bool(block.words) and ctx.kinds[block.start] == scan.COMMENT and size >= block_min
    oracle = is_block and ctx.texts[block.words[0]].startswith(ORACLE_PREFIXES)
    if not is_block or oracle or 2 * authored < size: return None
    code = _described_code(ctx, block)
    return ("L", f"{size}>{code}", block.words[0]) if size > code else None


def _described_code(ctx: _Context, block: Block) -> int:
    count = len(ctx.kinds)
    docs = [row for row in range(block.start, block.end) if row in ctx.doc]
    if docs and _indent(ctx.lines[docs[0]]) > 0: return _body(ctx, block.end, _indent(ctx.lines[docs[0]]) - 1)
    sig = _after_decorators(ctx, block.end)
    if sig < count and ctx.kinds[sig] in CODE_KINDS and SIGNATURE.match(ctx.lines[sig]):
        return _body(ctx, sig + 1, _indent(ctx.lines[sig]))
    blank_after = block.end < count and ctx.kinds[block.end] == scan.BLANK
    return _code_run(ctx, block.end + (1 if blank_after else 0))


def _after_decorators(ctx: _Context, row: int) -> int:
    depth = 0
    while row < len(ctx.kinds) and ctx.kinds[row] in CODE_KINDS:
        line = ctx.lines[row]
        if not depth and not line.lstrip().startswith("@"): break
        depth = max(0, depth + line.count("(") + line.count("[") - line.count(")") - line.count("]"))
        row += 1
    return row


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def _body(ctx: _Context, start: int, floor: int) -> int:
    lines = 0
    for row in range(start, len(ctx.kinds)):
        if ctx.kinds[row] not in CODE_KINDS: continue
        closes_signature = ctx.lines[row].lstrip().startswith((")", "]"))
        if _indent(ctx.lines[row]) <= floor and not closes_signature: break
        lines += 1
    return lines


def _code_run(ctx: _Context, start: int) -> int:
    run = itertools.takewhile(CODE_KINDS.__contains__, itertools.islice(ctx.kinds, start, None))
    return sum(1 for _ in run)


def _claims(ctx: _Context) -> list[Claim]:
    rows = [row for row in sorted(ctx.authored) if _WORD.search(ctx.texts.get(row, ""))]
    return [Claim(row + 1, ctx.texts[row]) for row in rows
            if any(pattern.search(ctx.texts[row]) for pattern in _CLAIM_RE)]


def finding_id(rule: str, path: str, text: str, occurrence: int = 1) -> str:
    """`D:<path>`, else `<rule>:<path>:<sha1(comment text)[:8]>`; a repeated text also hashes its count."""
    if rule == "D": return f"D:{path}"
    payload = text if occurrence <= 1 else f"{text}\x00{occurrence}"
    return f"{rule}:{path}:{hashlib.sha1(payload.encode('utf-8', 'surrogatepass')).hexdigest()[:HASH_WIDTH]}"


def apply_justifications(findings: Iterable[Finding], args: Iterable[str], cap: float) -> Justification:
    """Accept `ID=REASON` in argument order up to `cap`; an unknown id is stale and uses no slot.
    A malformed argument raises ValueError."""
    known = {finding.id for finding in findings}
    result = Justification({}, [], [])
    for arg in args:
        ident, reason = _split_justification(arg, known)
        reason = _FLATTEN.sub(" ", reason).strip()
        rejection = _rejection(ident, reason, result, cap) if ident in known else None
        if ident not in known: result.stale.append(ident)
        elif rejection: result.rejected.append(rejection)
        else: result.accepted[ident] = reason
    return result


def _split_justification(arg: str, known: AbstractSet[str]) -> tuple[str, str]:
    exact = sorted((ident for ident in known if arg.startswith(ident + "=")), key=len)
    if exact: return exact[-1], arg[len(exact[-1]) + 1:]
    hashed = _HASHED_ID.match(arg)
    if hashed: return arg[:hashed.end() - 1], arg[hashed.end():]
    ident, sep, reason = arg.partition("=")
    if not (sep and ident): raise ValueError(f"--justify {arg!r}: expected ID=REASON")
    return ident, reason


def _rejection(ident: str, reason: str, result: Justification, cap: float) -> Rejection | None:
    if ident in result.accepted: return Rejection(ident, DUPLICATE, "a second justification for the same id")
    if len(reason) < REASON_MIN: return Rejection(ident, SHORT, f"reason under {REASON_MIN} characters")
    if len(result.accepted) >= cap:
        return Rejection(ident, OVER_CAP, f"over the cap of {format_threshold(cap)} justifications per run")
    return None


def is_breach(findings: Iterable[Finding], justification: Justification) -> bool:
    """True when a finding is unjustified or a justification was over the cap."""
    over_cap = any(rejection.kind == OVER_CAP for rejection in justification.rejected)
    return over_cap or any(f.id not in justification.accepted for f in findings)


def verdict(findings: list[Finding], accepted: Mapping[str, str]) -> str:
    """`pass` without findings, `justified` when every finding is, else `breach`."""
    if not findings: return "pass"
    return "justified" if all(f.id in accepted for f in findings) else "breach"
