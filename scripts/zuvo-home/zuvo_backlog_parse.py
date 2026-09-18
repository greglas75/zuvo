"""Shared backlog parsing + the dedup key. Imported by backlog-collect.py and backlog-archive.py.

Not a script: no shebang, not executable. It is installed into ~/.zuvo/ alongside the helpers that
import it, and the underscore in the name is what makes `import zuvo_backlog_parse` work identically
in the repo checkout and on the flattened ~/.zuvo/ layout — a hyphenated name would force a dynamic
importlib load that mypy cannot see through.

THE LOAD-BEARING PART is `entry_key()`. A backlog entry must key the SAME open and resolved,
because the whole point is looking an entry up in the archive after it was closed. The pre-existing
`fingerprint` in backlog-collect.py cannot do that: it is `sha1(body[:200])` and `body` still
carries the resolution marker (that is exactly what `is_resolved_inline()` tests for), so the same
entry hashes differently once it is ticked. Keying on that would make every archive lookup miss,
silently, while the feature reads as working.
"""
import hashlib
import re
from typing import Iterator, NamedTuple

DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
ID_RE = re.compile(r"\bB-[\w.-]+\b")
SEV_RE = re.compile(r"\b(critical|high|medium|low|CRITICAL|WARNING|INFO)\b")
DONE_SECTION = re.compile(r"^#+\s*(resolved|done|closed|completed)", re.I)
OPEN_SECTION = re.compile(r"^#+\s*(open|backlog|deferred|todo)", re.I)
# A line that DOCUMENTS the format rather than recording an item.
TEMPLATE_RE = re.compile(
    r"(CRITICAL\s*/\s*HIGH|HIGH\s*/\s*MEDIUM|critical\|high\|medium|"
    r"<[a-z-]+>\s*\|\s*<|severity:\s*\[|\bfingerprint\s*\|\s*source-task\b)", re.I)
# Inline "already resolved" annotations used instead of a Resolved section/checkbox.
RESOLVED_MARKERS = ("FIXED", "RESOLVED", "DONE", "CLOSED", "WONTFIX", "OBSOLETE")

# An id at DEFINITION position: the entry is this item, rather than mentioning it. 44 B-* tokens
# appear in both files of the canonical backlog; only 5 are definitions — the other 39 are
# "see B-X" cross-references in prose. A guard that flags all 44 gets switched off in a week.
# The id may sit behind emphasis and short bracketed tags — MEASURED prefixes in the canonical
# backlog: "**" (385 lines), "**[S] " (249), "**[M] " (165), "**[S]** **" (99), "**[L]** **" (23).
# Missing those read the id as absent, which is worse than cosmetic: the archiver would mint a
# SECOND id for an entry that already has one, and the key would fall back to content — so a lookup
# by the real id would miss. Bounded repetition ({0,4}) keeps the match cheap and refuses prose:
# "see B-X" matches neither alternative, so a cross-reference is still not a definition.
_ID_PREFIX = r"(?:\*{0,2}\[[^\]]{1,20}\]\*{0,2}\s*|\*{1,2}\s*){0,4}"
DEF_ID_RE = re.compile(r"^[-*]\s*\[[ xX]\]\s*" + _ID_PREFIX + r"\[?(B-[\w.-]+)")
BODY_ID_RE = re.compile(r"^" + _ID_PREFIX + r"\[?(B-[\w.-]+)")
CHECKBOX_RE = re.compile(r"^[-*]\s*(\[[ xX]\]\s*)?")
HEADING_RE = re.compile(r"^#{1,6}\s+(.*)$")

_MARKER_ALT = "|".join(RESOLVED_MARKERS)
# A bracketed or parenthesised clause that exists only to record the resolution:
# "[FIXED abc1234]", "(FIXED 9178842d51 on refactor/logic-engine)", "[done]", "[REGRESSION …]".
_WRAPPED_MARKER_RE = re.compile(
    r"[\[(][^\[\]()]*\b(?:" + _MARKER_ALT + r"|REGRESSION)\b[^\[\]()]*[\])]", re.I)
_BARE_MARKER_RE = re.compile(r"\b(?:" + _MARKER_ALT + r")\b", re.I)
_SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b", re.I)
_PR_RE = re.compile(r"\bPR\s*#?\d+\b", re.I)
_CONF_RE = re.compile(r"\bconf(?:idence)?\s*[:=]?\s*\d+\b", re.I)
_SQUASH_RE = re.compile(r"\bsquash\b", re.I)
_PATH_RE = re.compile(r"\b[\w./@-]*[\w@-]\.[A-Za-z][A-Za-z0-9]{0,4}\b(?::\d+)?")
_WORD_RE = re.compile(r"[a-z0-9]+")


class Entry(NamedTuple):
    """One backlog line, with everything the archive lookup needs to answer in one shot."""

    lineno: int          # 1-based
    raw: str             # the line, byte-identical
    body: str            # post-checkbox text
    status: str          # "open" | "done"
    ident: str           # B-slug at definition position, or "" when the entry has none
    key: str             # "id:<slug>" or "fp:<sha1[:12]>"
    section: str         # nearest enclosing "##" heading, verbatim, or ""


def is_resolved_inline(body: str) -> bool:
    """True when the item body OPENS with a resolution marker.

    Repos annotate in place instead of moving the line to a Resolved section — both "FIXED: x" and
    "[FIXED] x" occur, so a regex with `\\s*` before the delimiter mis-parses one of them. Explicit
    prefix + boundary check covers every wrapper (**, [, spaces). DEFERRED is deliberately NOT a
    marker: a deferred item is still open.
    """
    b = body.lstrip("*[ \t").upper()
    # startswith + boundary, per marker: "DONEISH" must not read as DONE.
    return any(b.startswith(m) and (len(b) == len(m) or not b[len(m)].isalnum())
               for m in RESOLVED_MARKERS)


def has_resolution_marker(body: str) -> bool:
    """True when a resolution marker appears ANYWHERE, not only at the head.

    `is_resolved_inline` deliberately anchors at the start (that is what keeps "the DONE column"
    prose from marking an item resolved). Archiving needs the looser test as a *guard*: an entry
    is only archivable when it is ticked AND says why, and real entries put the marker mid-line
    ("B-GGPD-1 [RECOMMENDED] … conf 62 — DONE b9767b6a5").
    """
    return bool(_WRAPPED_MARKER_RE.search(body) or _BARE_MARKER_RE.search(body))


def valid_date(s: str) -> bool:
    """Reject impossible dates (a loose regex happily matches 2026-02-31)."""
    try:
        import datetime
        datetime.date.fromisoformat(s)
        return True
    except ValueError:
        return False


def strip_resolution_markers(text: str) -> str:
    """Remove everything that appears when an entry is CLOSED and is absent while it is open.

    Order matters: wrapped clauses go first (so "[FIXED abc1234]" leaves nothing behind), then bare
    markers, then the shrapnel that travels with them — commit shas, PR numbers, "squash",
    confidence, dates. Emphasis asterisks go too: "**B-X**" and "B-X" must key alike.
    """
    out = _WRAPPED_MARKER_RE.sub(" ", text)
    out = _BARE_MARKER_RE.sub(" ", out)
    out = _PR_RE.sub(" ", out)
    out = _SQUASH_RE.sub(" ", out)
    out = _CONF_RE.sub(" ", out)
    out = DATE_RE.sub(" ", out)
    out = _SHA_RE.sub(" ", out)
    out = out.replace("*", " ")
    return re.sub(r"\s+", " ", out).strip(" -—–|:.,")


def normalize_signature(body: str) -> str:
    """The content signature: first path-like token (basename) + the 8 words that FOLLOW it.

    Anchoring the word window AFTER the path is what makes the signature survive resolution: a
    closed entry carries leading prose the open one never had ("— DONE — PR #834 squash <sha> …"),
    and stripping markers cannot be exhaustive over free-form prose. Everything before the file
    name is therefore ignored rather than trusted. With no path token, fall back to the first 8
    words of the stripped text.
    """
    clean = strip_resolution_markers(body)
    m = _PATH_RE.search(clean)
    if m:
        path = m.group(0).split(":", 1)[0]
        base = path.rsplit("/", 1)[-1].lower()
        words = _WORD_RE.findall(clean[m.end():].lower())
        return base + "|" + " ".join(words[:8])
    return "|" + " ".join(_WORD_RE.findall(clean.lower())[:8])


def entry_key(body: str, ident: str = "") -> str:
    """`id:<slug>` when the entry is headed by a B-id, else `fp:<sha1[:12]>` of the signature."""
    if not ident:
        m = BODY_ID_RE.match(body.strip())
        ident = m.group(1) if m else ""
    if ident:
        return "id:" + ident.lower()
    return "fp:" + hashlib.sha1(normalize_signature(body).encode()).hexdigest()[:12]


def definition_id(raw_line: str) -> str:
    """The B-id this LINE defines (checkbox bullets only), or "" when it merely mentions one."""
    m = DEF_ID_RE.match(raw_line.strip())
    return m.group(1) if m else ""


def body_of(raw_line: str) -> str:
    return CHECKBOX_RE.sub("", raw_line.strip())


def iter_entries(text: str, *, checkbox_only: bool = False) -> Iterator[Entry]:
    """Yield entries with their enclosing `##` heading.

    `checkbox_only` is what the archive tooling uses: membership of the archive namespace is about
    real entries, and the archive also contains prose headers and notes. The fleet collector keeps
    the tolerant behaviour (bullets, tables, `- [B-N] text`) so it does not drop a dialect.
    """
    section = ""
    section_done = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            h = HEADING_RE.match(line.strip())
            if h:
                section = h.group(1).strip()
            if DONE_SECTION.match(line.strip()):
                section_done = True
            elif OPEN_SECTION.match(line.strip()):
                section_done = False
            continue

        stripped = line.strip()
        is_check = bool(re.match(r"^[-*]\s*\[[ xX]\]", stripped))
        is_item = stripped.startswith("- ") or stripped.startswith("* ")
        is_table = stripped.startswith("|") and bool(ID_RE.search(stripped))
        if checkbox_only:
            if not is_check:
                continue
        elif not (is_item or is_table):
            continue
        if is_table and set(stripped.replace("|", "").strip()) <= set("-: "):
            continue

        if re.match(r"^[-*]\s*\[[xX]\]", stripped):
            status = "done"
        elif re.match(r"^[-*]\s*\[\s\]", stripped):
            status = "open"
        elif is_table:
            status = "done" if re.search(r"\b(RESOLVED|DONE|CLOSED)\b", stripped) else "open"
        else:
            status = "done" if section_done else "open"

        body = body_of(stripped)
        if TEMPLATE_RE.search(body):
            continue
        if status == "open" and is_resolved_inline(body):
            status = "done"
        ident = definition_id(stripped)
        yield Entry(lineno=lineno, raw=raw, body=body, status=status, ident=ident,
                    key=entry_key(body, ident), section=section)


def parse_backlog(path: str, text: str) -> list:
    """Fleet-collector shape: one dict per item. `fingerprint` is kept BYTE-FOR-BYTE compatible
    (the collector schema and ~/.zuvo/backlog read it); `key` is the new resolution-stable id."""
    items = []
    for e in iter_entries(text):
        m_sev = SEV_RE.search(e.body)
        sev = m_sev.group(1).lower() if m_sev else ""
        sev = {"warning": "medium", "info": "low"}.get(sev, sev)
        m_date = DATE_RE.search(e.body)
        added = m_date.group(1) if m_date and valid_date(m_date.group(1)) else ""
        m_id = ID_RE.search(e.body)
        item_id = m_id.group(0) if m_id else "h-" + hashlib.sha1(e.body.encode()).hexdigest()[:10]
        items.append({
            "item_id": item_id,
            "status": e.status,
            "severity": sev,
            "added": added,
            "text": e.body[:400],
            "fingerprint": hashlib.sha1(e.body[:200].encode()).hexdigest()[:12],
            "key": e.key,
        })
    return items
