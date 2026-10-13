"""THE BACKLOG LINE `backlog-add` WRITES, and the in-place bump of one it wrote before.

THE LINE (one checkbox entry, so `archive`, `verify` and `drop-stale` work on it):

    - [ ] B-<stem>-<CLASS>-<fp8> <path>:<line> — [<CLASS>] <title> | evidence: <how> | fix: <fix> |
      severity: <sev> | source: <src>[, <src>…] | conf: NN | seen: N | ledger: F-<12> | <YYYY-MM-DD> [tag]

(one physical line; wrapped here). A finding with no repository file puts its target where
`<path>:<line>` goes. Every free-text field has its `|` escaped (`zuvo_backlog_admit.clean_text`), so an
unescaped ` | ` is always one of OUR separators — that is what lets `parse_own` read the tail fields
without a title such as "shows | seen: 9 |" hijacking them.

PROVEN VISIBLE, NOT ASSUMED. The parser silently skips a line that looks like format documentation
(`zb.TEMPLATE_RE`): measured, evidence containing `Map<K> | <V>` made the entry vanish, so `lookup`
would answer ABSENT for it for ever and every sighting would file it again. `_defuse` escapes each
TEMPLATE_RE trigger, and `render` then re-parses its own output with `self_check`: anything that is not
exactly one OPEN entry keyed `id:<b-id>` raises RenderInvisible ("render-invisible", CLI exit 1) rather
than being written. `self_check` is this module's ONE call into the parser's entry iterator, in the
pinned form `kinds=(zb.KIND_CHECKBOX,)` (H19c in test-backlog-headings.sh counts it).

ONLY OUR OWN LINES ARE EDITED. `bump` rewrites seen/conf/date/sources in place only on a line that
`parse_own` reads; a hand-written legacy line, a ticked line, or a REGRESSION re-open returns None and
the caller links it in the ledger without touching its text. So `render` refuses a line `parse_own`
cannot read back: it would be visible but never bumpable, and every re-sighting would only be linked.

REGRESSION is the protocol's re-open form (shared/includes/backlog-protocol.md), byte for byte, with
two deliberate deltas to the copied text: the severity band is raised one step, and the old `[pr:N]` /
`[branch:x]` tail is replaced by the CURRENT one — a merged PR's tag would make the intake ticket a
regression that so far exists only on a branch.

Whether an entry is already known is `zuvo_backlog_lookup`'s question, not this module's.
"""
from __future__ import annotations

import re
from typing import NamedTuple, Optional

import zuvo_backlog_admit as adm
import zuvo_backlog_parse as zb

ARCHIVE_NAME = "backlog-done.md"     # as the protocol and `lookup` spell it
SEVERITY_CAP = 40
MARKER_CAP = 120
BANDS = ("low", "medium", "high", "critical")
RENDER_INVISIBLE = "render-invisible"

_FID_RE = re.compile(r"F-[0-9a-f]{%d}" % adm.FP_HEX)
_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")
_TAG_RE = re.compile(r"\[(?:pr:[1-9][0-9]{0,8}|branch:[A-Za-z0-9._/-]+)\]")
_TAG_TAIL_RE = re.compile(r"\s*" + _TAG_RE.pattern + r"$")
# Each TEMPLATE_RE trigger a `|` escape does not already defuse, and the character to escape in it.
_DEFUSE = (
    (re.compile(r"(severity:\s*)\[", re.I), r"\1\\["),
    (re.compile(r"(CRITICAL\s*)/(\s*HIGH)", re.I), r"\1\\/\2"),
    (re.compile(r"(HIGH\s*)/(\s*MEDIUM)", re.I), r"\1\\/\2"),
)
_SOURCE = r"[a-z0-9:-]+"    # one source token as `parse_own` reads it back (admit's `drive-by:x` fits)
_SOURCE_RE = re.compile(_SOURCE)
_OWN_RE = re.compile(
    r"^- \[ \] (?P<id>B-[\w.-]+) (?P<loc>.+?) — \[(?P<cls>[A-Z-]+)\] (?P<title>.*?)"
    r" \| evidence: (?P<ev>.*?) \| fix: (?P<fix>.*?) \| severity: (?P<sev>.*?)"
    r" \| source: (?P<src>%s(?:, %s)*) \| conf: (?P<conf>\d{1,3}) \| seen: (?P<seen>\d+)"
    r" \| ledger: (?P<fid>F-[0-9a-f]{%d}) \| (?P<date>\d{4}-\d{2}-\d{2})(?P<tag> %s)?$"
    % (_SOURCE, _SOURCE, adm.FP_HEX, _TAG_RE.pattern))
_SEV_FIELD_RE = re.compile(r"(?<!\\)(\| severity: )(\w+)( \|)")   # an escaped `\|` is title text


class RenderInvisible(RuntimeError):
    """The rendered line is not exactly one open entry keyed by its id, or not one `parse_own` reads
    back; nothing may be written."""

    def __init__(self) -> None:
        super().__init__(RENDER_INVISIBLE)


class Own(NamedTuple):
    """The tail fields of a line in `render`'s own format."""
    b_id: str
    sources: tuple[str, ...]
    conf: int
    seen: int
    f_id: str
    date: str
    tag: str                       # "" or the tag, without its leading space


def _defuse(text: str) -> str:
    """Escape every TEMPLATE_RE trigger. Applied to the WHOLE assembled line, because a trigger can span
    our own text and a value: `| severity: ` followed by a severity of `[x]` is `severity: [`."""
    out = text
    for rx, repl in _DEFUSE:
        out = rx.sub(repl, out)
    return out


def _field(text: Optional[str], cap: int) -> str:
    """One free-text field: cleaned (one line, pipes escaped, capped), `-` when empty."""
    return adm.clean_text(text, cap) or "-"


def _check_date(today: str) -> None:
    if not (_DATE_RE.fullmatch(today) and zb.valid_date(today)):
        raise ValueError(f"not a date: {today!r}")


def _check_tag(tag: str) -> None:
    if tag and not _TAG_RE.fullmatch(tag):
        raise ValueError(f"not a [pr:N] / [branch:name] tag: {tag!r}")


def _check_source(source: str) -> None:
    if not _SOURCE_RE.fullmatch(source):
        raise ValueError(f"not a source token: {source!r}")


def _tail(tag: str) -> str:
    return f" {tag}" if tag else ""


def self_check(line: str, b_id: str) -> bool:
    """True iff `line` parses as exactly one OPEN entry, byte-identical, keyed `id:<b_id>`."""
    found = list(zb.iter_entries(line, kinds=(zb.KIND_CHECKBOX,)))
    return (len(found) == 1 and found[0].status == "open" and found[0].raw == line
            and found[0].key == "id:" + b_id.lower())


def _checked(line: str, b_id: str) -> str:
    if not self_check(line, b_id):
        raise RenderInvisible()
    return line


def _location(f: adm.Finding) -> str:
    if f.target and f.target.strip():
        return _field(f.target.strip(), adm.TITLE_CAP)
    path = f.file or ""
    while path.startswith("./"):
        path = path[2:]
    return f"{_field(path, adm.TITLE_CAP)}:{f.line}"


def render(f: adm.Finding, decision: adm.Decision, b_id: str, f_id: str, seen: int, tag: str,
           today: str) -> str:
    """The backlog line for an admitted finding, without a newline. Raises ValueError on a malformed
    f_id/seen/tag/today (a caller bug) and RenderInvisible when the parser would not see the result or
    `parse_own` could not read it back (a visible line that could never be bumped)."""
    if not _FID_RE.fullmatch(f_id):
        raise ValueError(f"not an F-id: {f_id!r}")
    if seen < 1:
        raise ValueError(f"seen must be >= 1, got {seen}")
    _check_tag(tag)
    _check_date(today)
    conf = adm.parse_conf(f.conf)
    if conf is None:
        raise ValueError(f"not a confidence: {f.conf!r}")
    line = _defuse(f"- [ ] {b_id} {_location(f)} — [{decision.cls}] {decision.title}"
                   f" | evidence: {_field(f.evidence, adm.EVIDENCE_CAP)} | fix: {_field(f.fix, adm.FIX_CAP)}"
                   f" | severity: {_field(f.severity, SEVERITY_CAP)} | source: {f.source} | conf: {conf}"
                   f" | seen: {seen} | ledger: {f_id} | {today}{_tail(tag)}")
    if parse_own(_checked(line, b_id)) is None:
        raise RenderInvisible()
    return line


def raise_band(sev: str) -> str:
    """One severity band up (`critical` stays), upper-case kept, any other case lowered; unknown kept."""
    low = sev.lower()
    if low not in BANDS:
        return sev
    up = BANDS[min(BANDS.index(low) + 1, len(BANDS) - 1)]
    return up.upper() if sev.isupper() else up


def _archived_text(archived_line: str) -> str:
    """The archived entry's text after its id: checkbox, heading hashes and the id token removed."""
    body = zb.body_of(archived_line.strip().lstrip("#").strip())
    return zb.strip_ident(body).strip()


def _split_marker(text: str) -> tuple[str, str]:
    """(problem text, closing marker). The marker is the RIGHTMOST caps-or-wrapped verdict, the one
    `heading_resolution_pos` reads, so a lowercase "closed" in the prose is not taken for it."""
    pos = zb.heading_resolution_pos(text)
    if pos < 0:
        return text, "(bare tick)"
    problem = text[:pos].rstrip(" —–-")
    marker = adm.clean_text(text[pos:], MARKER_CAP)
    return (problem or text), marker


def render_regression(b_id: str, archived_line: str, section: str, source: str, conf: int, tag: str,
                      today: str) -> str:
    """The protocol's re-open line for an ARCHIVED entry seen again (no newline). Raises ValueError on a
    malformed source/conf/tag/today — the same bars `render` applies to its own line — and RenderInvisible
    when the parser would not see the result."""
    _check_source(source)
    valid_conf = adm.parse_conf(conf)
    if valid_conf is None:
        raise ValueError(f"not a confidence: {conf!r}")
    _check_tag(tag)
    _check_date(today)
    problem, marker = _split_marker(_archived_text(archived_line))
    problem = _TAG_TAIL_RE.sub("", problem).rstrip()
    problem = _SEV_FIELD_RE.sub(lambda m: m.group(1) + raise_band(m.group(2)) + m.group(3), problem)
    heading = adm.clean_text(section, adm.TITLE_CAP).replace('"', "'")
    line = _defuse(f"- [ ] {b_id} [REGRESSION {today} — closed {marker}, archived in "
                   f'{ARCHIVE_NAME} "{heading}"] {problem} | re-observed by {source} | conf: {valid_conf}'
                   f"{_tail(tag)}")
    return _checked(line, b_id)


def _own(m: "re.Match[str]") -> Own:
    return Own(m["id"], tuple(m["src"].split(", ")), int(m["conf"]), int(m["seen"]), m["fid"], m["date"],
               (m["tag"] or "").strip())


def parse_own(line: str) -> Optional[Own]:
    """The tail fields when `line` (newline allowed) is an OPEN line in `render`'s format, else None."""
    m = _OWN_RE.match(line.rstrip("\r\n"))
    return _own(m) if m is not None else None


def _bumped(line: str, m: "re.Match[str]", conf: int, source: str, today: str) -> str:
    """`line` with its tail rebuilt from the match `m` of its content; the line ending is kept."""
    own = _own(m)
    sources = own.sources if source in own.sources else (*own.sources, source)
    return (line[:m.start("src")] + ", ".join(sources) + f" | conf: {max(own.conf, conf)}"
            f" | seen: {own.seen + 1} | ledger: {own.f_id} | {today}{_tail(own.tag)}"
            + line[len(line.rstrip("\r\n")):])


def bump(lines: list[str], b_id: str, conf: int, source: str, today: str) -> Optional[list[str]]:
    """A copy of `lines` with the FIRST line defining `b_id` re-sighted: seen + 1, conf = max,
    date = today, `source` added once. None when that line is in another format (link, never edit):
    the first definition is the one the archiver's lookup answers with, so a later duplicate is not it.
    Raises ValueError when no line defines `b_id` or `today` is not a date."""
    _check_date(today)
    first = next((i for i, ln in enumerate(lines) if zb.definition_id(ln).lower() == b_id.lower()), None)
    if first is None:
        raise ValueError(f"no line defines {b_id}")
    m = _OWN_RE.match(lines[first].rstrip("\r\n"))
    if m is None:
        return None
    out = list(lines)
    out[first] = _bumped(lines[first], m, conf, source, today)
    return out

