"""THE ADMISSION BARS of `backlog-add`: what may become a backlog entry, what is kept only as data in
the findings ledger, and what is refused. Pure functions: no I/O, no subprocess, no clock.

WHY BARS AT ALL. `memory/backlog.md` must hold only work that becomes a ticket: a downstream intake
tickets it. So only BUG, SEC and DATA findings that clear their bar land there. Everything else at
conf >= FLOOR is still KEPT, as a ledger record, never dropped.

PRECEDENCE, in this order and no other:
  1. validation — a refusal is final, whatever else is true;
  2. the confidence floor — below FLOOR is discarded, forced or not;
  3. the env override (`ZUVO_BACKLOG_ADMIT=1`, read by the CLI, passed here as `forced`) — any class
     at conf >= FLOOR goes to the backlog. `Decision.forced` is True only when it CHANGED the route,
     so the record says which entries bypassed the bars rather than which ran with the env set;
  4. the bar table in `_natural`.

IDENTITY. `fingerprint` never reads the confidence, the line number or the rendered title, and always
uses the finding's ORIGINAL class: the SEC low-confidence prefix is added after hashing, and a
TEST-GAP promoted to BUG keeps the F-id it had while it sat in the ledger. Paths arrive repo-relative
(`zuvo_backlog_vcs.normalize_path` makes them so); only a leading `./` is stripped here.

NAMING. No module-level name starts with `RC_`: test-backlog-grooming.sh scans `RC_*` integers across
every `zuvo_backlog_*.py` for exit-code collisions, and these constants are not exit codes. The parser
is imported in the `import` form and its entry iterator is never called (not even named here), which
keeps this module on the `*)` arm of the H19c pin guard in test-backlog-headings.sh.
"""
from __future__ import annotations

import hashlib
import ipaddress
import re
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import AbstractSet, Callable, FrozenSet, NamedTuple, Optional, Tuple, cast
from urllib.parse import urlsplit

import zuvo_backlog_parse as zb

BACKLOG_CLASSES: FrozenSet[str] = frozenset({"BUG", "SEC", "DATA"})
# Report-only only when a skill can name the missing assertion on a changed line (see `_promotion`).
PROMOTABLE_CLASSES: FrozenSet[str] = frozenset({"TEST-GAP", "MUTATION"})
REPORT_ONLY_CLASSES: FrozenSet[str] = frozenset(
    {"DUP", "CPLX", "SIZE", "PERF", "DEAD", "READ", "CQ", "PROCESS"}) | PROMOTABLE_CLASSES
CLASSES: FrozenSet[str] = BACKLOG_CLASSES | REPORT_ONLY_CLASSES | {"ADVISORY"}

FLOOR = 26          # below it a finding is discarded, forced or not
SEC_LOW = 51        # a SEC finding below it lands with LOW_CONF_PREFIX
BACKLOG_MIN = 80    # BUG / DATA / a promoted gap need at least this
LOW_CONF_PREFIX = "(low confidence — verify manually) "
TITLE_CAP, EVIDENCE_CAP, FIX_CAP = 200, 600, 300
_ANCHOR_MIN = 8     # non-space characters an anchor needs to locate one line rather than many
IDENTITY_WORDS = 8  # title words that make a finding's identity: enough to tell two apart, few enough
                    # that a reworded tail does not split one finding in two
FP_HEX = 12         # hex digits of sha1 in an F-id (`F-` + FP_HEX)
B_ID_HASH = 8       # leading F-id hex digits carried into a B-id

ROUTE_BACKLOG, ROUTE_LEDGER, ROUTE_DISCARDED, ROUTE_REFUSED = "backlog", "ledger", "discarded", "refused"
ROUTES: Tuple[str, ...] = (ROUTE_BACKLOG, ROUTE_LEDGER, ROUTE_DISCARDED, ROUTE_REFUSED)

# Why a finding took its route. Closed: the ledger record's `reason` is always one of these.
# `branch-untaggable` is decided by the CLI (it needs the branch), not here, but it lives in the set.
REASONS: FrozenSet[str] = frozenset({
    "admitted", "forced", "promoted", "below-floor", "conf-below-80", "mutation-not-on-changed-line",
    "class-report-only", "advisory", "branch-untaggable"})
# Refusal reasons (exit 3), printed `<reason>:<field>` for the two field kinds. `file-or-target` is
# compound because either will do. `bad-field` refuses a wrong TYPE before a later check crashes on it.
# The last two need the work tree (zuvo_backlog_vcs.check_site); listed here so the vocabulary has one home.
REFUSALS: FrozenSet[str] = frozenset({
    "unknown-class", "missing-field", "bad-field", "bad-conf", "bad-source", "bad-target", "bad-path",
    "bad-combination", "path-outside-repo", "line-out-of-range", "secret-like-value",
    "file-not-in-worktree", "anchor-not-at-line"})

_SOURCE_RE = re.compile(r"(?:drive-by:)?[a-z0-9-]+")
# ASCII digits only: `int()` also reads Arabic-Indic and other Unicode digits, which no CLI means.
_CONF_TEXT_RE = re.compile(r"[0-9]{1,3}")
_LINE_TEXT_RE = re.compile(r"[0-9]{1,9}")
_LINE_LIMIT = 10 ** 9   # the first line the 9-digit text form cannot carry; an int is held to it too
_URL_RE = re.compile(r"https?://[^\s/?#]+\S*")
_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
_HOSTNAME_RE = re.compile(_LABEL + r"(?:\." + _LABEL + r")*")
_PORT_RE = re.compile(r"[0-9]{1,5}")
_PORT_MAX = 65535
_SUBJECT_RE = re.compile(r"subject:[a-z0-9][a-z0-9._-]{0,79}")
# Which classes each target kind may carry: URL/host for live-system findings (pentest, infra-audit,
# --live-url audits), `subject:` for process items and SEC.
_TARGET_CLASSES = {"url": BACKLOG_CLASSES, "host": BACKLOG_CLASSES,
                   "subject": frozenset({"PROCESS", "SEC"})}
# Prefixed provider keys (`sk-ant-…`, `sk-proj-…`), every GitHub token kind, a JWT's two `eyJ` parts, and
# a URL carrying `user:password@` (a DSN) in any field, not only in `--target`.
_SECRET_RES = tuple(re.compile(p) for p in (
    r"\bAKIA[0-9A-Z]{16}\b", r"\bgh[pousr]_[A-Za-z0-9]{30,}", r"\bsk-[A-Za-z0-9]{20,}",
    r"\bsk-(?:ant|proj|svcacct|admin)-[A-Za-z0-9_-]{20,}", r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.",
    r"-----BEGIN [A-Z ]*PRIVATE KEY", r"\bxox[aboprs]-", r"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])",
    r"\b(?:sk|rk)_live_[0-9A-Za-z]{16,}", r"\bgithub_pat_[0-9A-Za-z_]{22,}", r"\bglpat-[0-9A-Za-z_-]{20,}",
    r"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]*:[^\s/@]+@"))     # the user may be empty: redis://:pw@
# `user:pw@` in front of a URL's or a host's address: a credential in the target itself.
_USERINFO_RE = re.compile(r"(?:[A-Za-z][A-Za-z0-9+.-]*://)?[^\s/?#@]*@")
# Every line break a renderer might honour, including NEL and the Unicode line/paragraph separators.
_NEWLINE_RE = re.compile(r"\r\n?|[\n\u0085\u2028\u2029]")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# A lone surrogate: argv bytes that are not UTF-8 arrive as these (surrogateescape) and cannot be written.
UNENCODABLE_RE = re.compile("[\ud800-\udfff]")
# A path or target that would break the rendered `<location>:<line>` or the `|` field layout. Refused
# rather than escaped, so the location in the backlog is byte-for-byte what the skill reported.
_BAD_LOCATION_RE = re.compile(r"[\x00-\x1f\x7f-\x9f|\u2028\u2029]")
_WORD_RE = re.compile(r"\w+")            # Unicode-aware: a Cyrillic title has words
_STEM_BAD_RE = re.compile(r"[^A-Za-z0-9_.-]+")   # ASCII subset of [\w.-]: downstream \w may be ASCII
_FID_RE = re.compile(r"F-([0-9a-f]{%d})" % FP_HEX)
_STEM_CAP = 40


@dataclass(frozen=True)
class Finding:
    """One finding as a skill reports it. `conf` is int or the CLI's text; `validate` decides."""
    cls: str
    conf: int | str | None
    source: str
    title: str
    file: Optional[str] = None
    line: int | str | None = None
    anchor: Optional[str] = None
    target: Optional[str] = None
    evidence: Optional[str] = None
    fix: Optional[str] = None
    severity: Optional[str] = None
    missing_assertion: Optional[str] = None


class Decision(NamedTuple):
    route: str      # one of ROUTES
    reason: str     # one of REASONS, or a refusal (`missing-field:<f>` for that one)
    cls: str        # the class the entry is RENDERED with (BUG for a promoted gap); "" on a refusal
    title: str      # cleaned, with LOW_CONF_PREFIX when it applies; "" on a refusal
    forced: bool    # True only when the env override changed the route


def _present(s: Optional[str]) -> bool:
    return bool(s and s.strip())


def _parse_int(raw: object, text_re: re.Pattern[str]) -> Optional[int]:
    """An int from an int (never a bool, which is an int subclass) or from digit text; else None."""
    if isinstance(raw, str):
        text = raw.strip()
        return int(text) if text_re.fullmatch(text) else None
    return raw if isinstance(raw, int) and not isinstance(raw, bool) else None


def parse_conf(raw: object) -> Optional[int]:
    """The confidence as an int 0-100, or None. `"85.0"`, `85.0`, `True` and `-1` are not confidences."""
    conf = _parse_int(raw, _CONF_TEXT_RE)
    return conf if conf is not None and 0 <= conf <= 100 else None


def parse_line(raw: object) -> Optional[int]:
    """The line as an int >= 1, or None. The CLI hands over text; `12.0` and `True` are not lines."""
    line = _parse_int(raw, _LINE_TEXT_RE)
    return line if line is not None and 1 <= line < _LINE_LIMIT else None


def _hostname_ok(host: str) -> bool:
    """A DNS name or IPv4 address in label form, or an IP literal (a URL's bracketed IPv6)."""
    if _HOSTNAME_RE.fullmatch(host):
        return True
    try:
        ipaddress.ip_address(host)
    except ValueError:
        return False
    return True


def _url_host(url: str) -> Optional[str]:
    """The host of a URL, or None when it is not one a bare-host target could also name: `urlsplit`
    cannot read it (`https://[::1/x`, port 99999) or it is not a hostname (`https://foo\\bar.com`)."""
    try:
        parts = urlsplit(url)
        _ = parts.port          # raises ValueError on a port it cannot read
    except ValueError:
        return None
    host = parts.hostname
    return host if host and _hostname_ok(host) else None


def _bare_host_ok(target: str) -> bool:
    """`name` or `name:port`, the port held to the range `urlsplit` enforces for a URL's port."""
    host, sep, port = target.partition(":")
    if sep and not (_PORT_RE.fullmatch(port) and int(port) <= _PORT_MAX):
        return False
    return bool(_HOSTNAME_RE.fullmatch(host))


def target_kind(target: Optional[str]) -> Optional[str]:
    """`url`, `host`, `subject`, or None when the text is none of the three shapes."""
    t = (target or "").strip()
    if _BAD_LOCATION_RE.search(t):
        return None
    if _URL_RE.fullmatch(t):
        return "url" if _url_host(t) else None
    if _SUBJECT_RE.fullmatch(t):
        return "subject"
    return "host" if _bare_host_ok(t) else None


def clean_text(s: Optional[str], cap: int) -> str:
    """One safe backlog field: line breaks and control characters become spaces, the text is cut at
    `cap` SOURCE characters (marked with `…`), and only then escaped — every `\\` becomes `\\\\`, then
    every `|` becomes `\\|`. Cutting first means an escape pair can never be split; escaping every
    backslash means the field never ends in an odd run of them, which would escape the renderer's own
    ` | ` separator that follows, and a `\\|` already in the text cannot turn into an open column."""
    if not s:
        return ""
    flat = _CONTROL_RE.sub(" ", _NEWLINE_RE.sub(" ", s)).strip()
    if len(flat) > cap:
        flat = flat[:cap - 1].rstrip() + "…"
    return flat.replace("\\", "\\\\").replace("|", "\\|")


_TEXT_FIELDS = ("cls", "source", "title", "file", "anchor", "target", "evidence", "fix", "severity",
                "missing_assertion")


def _check_types(f: Finding) -> Optional[str]:
    # First, so that no later check calls `.strip()` on a number or hashes a list.
    for name in _TEXT_FIELDS:
        value = getattr(f, name)
        if value is not None and (not isinstance(value, str) or UNENCODABLE_RE.search(value)):
            return "bad-field:" + name      # not text, or text no file can hold (only found AT the write)
    return None


def _check_class(f: Finding) -> Optional[str]:
    if not _present(f.cls):
        return "missing-field:class"
    return None if f.cls in CLASSES else "unknown-class"


def _check_conf(f: Finding) -> Optional[str]:
    if f.conf is None or (isinstance(f.conf, str) and not f.conf.strip()):
        return "missing-field:conf"
    return None if parse_conf(f.conf) is not None else "bad-conf"


def _check_source(f: Finding) -> Optional[str]:
    if not _present(f.source):
        return "missing-field:source"
    return None if _SOURCE_RE.fullmatch(f.source) else "bad-source"


def _check_title(f: Finding) -> Optional[str]:
    # The CLEANED title, because that is what gets rendered: a title of only control characters would
    # otherwise pass here and land as an empty entry.
    return None if clean_text(f.title, TITLE_CAP) else "missing-field:title"


def _check_file(f: Finding) -> Optional[str]:
    raw = f.file or ""
    if raw != raw.strip() or _BAD_LOCATION_RE.search(raw):
        return "bad-path"
    path = _strip_dot(raw)
    parts = PurePosixPath(path).parts      # empty for "" and "." alike: the repo root is not a file
    if not parts or path.startswith("/") or ".." in parts:
        return "path-outside-repo"
    if f.line is None or (isinstance(f.line, str) and not f.line.strip()):
        return "missing-field:line"
    if parse_line(f.line) is None:
        return "line-out-of-range"
    anchor_len = len("".join((f.anchor or "").split()))
    if f.cls in BACKLOG_CLASSES and anchor_len < _ANCHOR_MIN:
        return "missing-field:anchor"
    return None


def _check_target(f: Finding) -> Optional[str]:
    kind = target_kind(f.target)
    if kind is None:
        return "bad-target"
    if f.cls not in _TARGET_CLASSES[kind]:
        return "bad-combination"
    if kind != "subject" and not _present(f.evidence):
        return "missing-field:evidence"
    return None


def _check_location(f: Finding) -> Optional[str]:
    has_file, has_target = _present(f.file), _present(f.target)
    if has_file and has_target:
        return "bad-combination"            # nothing is missing; the two exclude each other
    if not (has_file or has_target):
        return "missing-field:file-or-target"
    return _check_target(f) if has_target else _check_file(f)


def _check_combination(f: Finding) -> Optional[str]:
    if _present(f.missing_assertion) and f.cls not in PROMOTABLE_CLASSES:
        return "bad-combination"
    return None


def _check_secrets(f: Finding) -> Optional[str]:
    # Every text field, because every one is stored: a lowercase `sk-…` key even passes `_SOURCE_RE`.
    texts = [cast(Optional[str], getattr(f, name)) for name in _TEXT_FIELDS]
    hit = any(rx.search(t) for t in texts if t for rx in _SECRET_RES)
    userinfo = bool(f.target and _USERINFO_RE.match(f.target.strip()))
    return "secret-like-value" if hit or userinfo else None


# Secrets come before the location checks: a credential in a target must be refused as one, not as a
# malformed target (`user:pw@db.internal` is not a valid host shape either).
_CHECKS: Tuple[Callable[[Finding], Optional[str]], ...] = (
    _check_types, _check_class, _check_conf, _check_source, _check_title, _check_secrets,
    _check_location, _check_combination)


def validate(f: Finding) -> Optional[str]:
    """The refusal reason (exit 3), or None. The first failing check wins, in `_CHECKS` order."""
    for check in _CHECKS:
        reason = check(f)
        if reason is not None:
            return reason
    return None


def _promotion(f: Finding, conf: int, changed_lines: AbstractSet[int], title: str) -> Decision:
    """A gap with a named missing assertion becomes a BUG only at conf >= BACKLOG_MIN AND when the cited
    production line is in the branch diff — an old gap is debt, a gap in new code is a defect."""
    if conf < BACKLOG_MIN:
        return Decision(ROUTE_LEDGER, "conf-below-80", f.cls, title, False)
    if parse_line(f.line) not in changed_lines:
        return Decision(ROUTE_LEDGER, "mutation-not-on-changed-line", f.cls, title, False)
    return Decision(ROUTE_BACKLOG, "promoted", "BUG", title, False)


def _natural(f: Finding, conf: int, changed_lines: AbstractSet[int]) -> Decision:
    title = clean_text(f.title, TITLE_CAP)
    if f.cls == "SEC":
        shown = LOW_CONF_PREFIX + title if conf < SEC_LOW else title
        return Decision(ROUTE_BACKLOG, "admitted", f.cls, shown, False)
    if f.cls in BACKLOG_CLASSES:
        admitted = conf >= BACKLOG_MIN
        return Decision(ROUTE_BACKLOG if admitted else ROUTE_LEDGER,
                        "admitted" if admitted else "conf-below-80", f.cls, title, False)
    if f.cls in PROMOTABLE_CLASSES and _present(f.missing_assertion):
        return _promotion(f, conf, changed_lines, title)
    reason = "advisory" if f.cls == "ADVISORY" else "class-report-only"
    return Decision(ROUTE_LEDGER, reason, f.cls, title, False)


def decide(f: Finding, changed_lines: AbstractSet[int], forced: bool) -> Decision:
    """Route one finding. `changed_lines` holds the branch-diff lines of `f.file` (only a promotion
    reads it); `forced` is the CLI's reading of `ZUVO_BACKLOG_ADMIT=1`. See PRECEDENCE above."""
    refusal = validate(f)
    if refusal is not None:
        return Decision(ROUTE_REFUSED, refusal, "", "", False)   # never echo an unvalidated class
    # `validate` refused every conf `parse_conf` rejects (`_check_conf`), so this is an int here.
    conf = cast(int, parse_conf(f.conf))
    if conf < FLOOR:
        return Decision(ROUTE_DISCARDED, "below-floor", f.cls, "", False)
    natural = _natural(f, conf, changed_lines)
    if forced and natural.route != ROUTE_BACKLOG:
        return Decision(ROUTE_BACKLOG, "forced", f.cls, natural.title, True)
    return natural


def _strip_dot(path: str) -> str:
    while path.startswith("./"):
        path = path[2:]
    return path


def _target_key(target: str) -> str:
    return target.strip().lower().rstrip("/")


def _identity_text(f: Finding) -> str:
    """The normalised anchor for an anchored BUG/SEC/DATA (paraphrased titles collapse), else the first
    IDENTITY_WORDS words of the marker-stripped title, else — a title with no word at all — the whole
    title."""
    if f.cls in BACKLOG_CLASSES and f.anchor and f.anchor.strip():
        return " ".join(f.anchor.split()).lower()
    words = _WORD_RE.findall(zb.strip_resolution_markers(f.title).lower())
    return " ".join(words[:IDENTITY_WORDS]) if words else " ".join(f.title.lower().split())


def fingerprint(f: Finding) -> str:
    """`F-` + sha1[:FP_HEX] of `CLASS | where | identity`, with `f.cls` the ORIGINAL class."""
    where = _target_key(f.target) if f.target and f.target.strip() else _strip_dot(f.file or "")
    key = f"{f.cls}|{where}|{_identity_text(f)}"
    return "F-" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:FP_HEX]


def _stem(f: Finding) -> str:
    t = (f.target or "").strip()
    kind = target_kind(t) if t else None
    if kind == "url":
        raw = _url_host(t) or ""
    elif kind == "host":
        raw = t.split(":", 1)[0]
    elif kind == "subject":
        raw = t.split(":", 1)[1]
    else:
        raw = PurePosixPath(_strip_dot(f.file or "")).stem
    stem = _STEM_BAD_RE.sub("-", raw).strip("-")[:_STEM_CAP].strip("-")
    return stem or "file"


def b_id(f: Finding, decision: Decision, fp: str) -> str:
    """`B-<stem>-<RENDERED class>-<fp8>`. The class is `decision.cls` (BUG for a promoted gap), the
    hash comes from `fp`, the F-id of the ORIGINAL class. Raises ValueError when `fp` is not an F-id."""
    m = _FID_RE.fullmatch(fp)
    if m is None:
        raise ValueError(f"b_id: {fp!r} is not an F-id (F- + {FP_HEX} hex)")
    return f"B-{_stem(f)}-{decision.cls}-{m.group(1)[:B_ID_HASH]}"
