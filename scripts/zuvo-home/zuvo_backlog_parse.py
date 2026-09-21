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
import subprocess
from typing import Iterator, NamedTuple, Optional, List

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
# Measured across every archive in the fleet, not chosen: 508 archived entries carried no marker from
# the original six, and the tags on them show the vocabulary was simply too narrow. "WYSLANE fala 5 —
# PR #83" (191 occurrences) means the finding went upstream in a PR; "ZROBIONE", "ROZSTRZYGNIETE"
# (settled from the code) and "[not a bug]" are verdicts too. The gap was not cosmetic: `drop-stale`
# refused a whole 20-id batch because the archived copy said "[not a bug]", and the archiver filed
# entries under "no recorded resolution" that plainly recorded one.
RESOLVED_MARKERS = ("FIXED", "RESOLVED", "DONE", "CLOSED", "WONTFIX", "OBSOLETE",
                    "ZROBIONE", "ROZSTRZYGNIETE", "ROZSTRZYGNIĘTE", "ROZWIĄZANE", "ROZWIAZANE")
# Recognised ONLY inside a bracketed/parenthesised clause. "stale" and "obalony" are ordinary words
# ("a stale cache", "teza obalona w akapicie") and matching them bare would mark unresolved entries
# resolved — the false-positive direction that silently loses work. "[STALE — zweryfikowane w kodzie]"
# and "[not a bug]" are verdicts; `stale cache` in prose is not.
# Two groups, because one rule cannot fit both shapes found in the real data.
#
# CAPS: single words that are ordinary Polish/English participles in prose but VERDICT STAMPS when
# shouted. Measured forms: "[WYSLANE fala 5 — PR #83]" (191 occurrences), "[STALE — zweryfikowane w
# kodzie]". Prose counterexamples an adversarial pass produced, all lowercase: "(stale-index bug
# remains unfixed)", "(stale cache invalidation still broken)", "teza obalony w akapicie trzecim".
# So the discriminator is CASE, not a delimiter — a delimiter rule rejected the 191-occurrence form
# because "WYSLANE fala 5" continues with an ordinary word.
WRAPPED_CAPS_MARKERS = ("STALE", "OBALONE", "OBALONY", "WYSLANE", "WYSŁANE")
# ANY-CASE: multi-word phrases that are unambiguous by construction. They still need a delimiter, or
# "(not a bug tracker feature request)" would read as a verdict.
WRAPPED_ANYCASE_MARKERS = ("NOT A BUG", "NO REPRO")
WRAPPED_ONLY_MARKERS = WRAPPED_CAPS_MARKERS + WRAPPED_ANYCASE_MARKERS

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
# The wrapped-only verdicts must OPEN the clause. Measured false positive that forced this: the entry
# "B-R12 RankingHandler wired to use dragRanking (also fixes inline stale-index bug)" was read as
# resolved, because `\bstale\b` matches inside "stale-index" and the clause was parenthesised. The
# text is prose about a bug, not a verdict. "[STALE — zweryfikowane w kodzie]" and "[not a bug]" open
# with the verdict; prose mentioning a stale cache does not.
# The marker must OPEN the clause AND be followed by a delimiter. Opening alone was not enough — an
# adversarial pass produced "(stale-index bug remains unfixed)" and "(stale cache invalidation still
# broken)", which both open with "stale" and are plainly not verdicts. Real verdicts close the clause
# or set the reason off with a dash or colon: "[STALE — zweryfikowane w kodzie]", "[not a bug]".
_WRAPPED_CAPS_ALT = "|".join(WRAPPED_CAPS_MARKERS)
_WRAPPED_ANY_ALT = "|".join(WRAPPED_ANYCASE_MARKERS)
# CAPS group: case-SENSITIVE (no re.I) and allowed BRACKETED OR BARE. Bare-in-caps is a real recorded
# form — "OBALONE 2026-09-20, wpis był NIEPRAWDZIWY" in tgm-pulse — and requiring a bracket would have
# re-classified it as unrecorded. Case alone separates it from the prose counterexamples, which are all
# lowercase. ANY-CASE group: case-insensitive, so it still needs the clause end or a dash/colon.
_WRAPPED_VERDICT_RE = re.compile(r"\b(?:" + _WRAPPED_CAPS_ALT + r")\b")
_WRAPPED_PHRASE_RE = re.compile(
    r"[\[(][*_\s]*(?:" + _WRAPPED_ANY_ALT + r")\b(?=\s*[\])]|\s*[—–:,]|\s*$)", re.I)
# `(?<!\bnie )` because Polish negates with a SEPARATE preceding word: "nie zrobione" (not done) and
# "nie rozwiązane" (not resolved) contain the marker verbatim, so a bare match called them closed —
# found by an adversarial pass with "wyslane do przegladu ale nie zrobione". Fixed-width lookbehind,
# which Python's re supports.
_BARE_MARKER_RE = re.compile(r"(?<!\bnie )\b(?:" + _MARKER_ALT + r")\b", re.I)
# The contract's re-open marker. An open entry carrying it is allowed to share an id with an archived
# one — that IS the regression path, and `verify` must not flag what the protocol requires.
# "nawrót" is here because the fleet's largest backlog already records regressions that way ("— nawrót
# po #830"), and a gate that flagged two genuine regressions as violations is a gate that gets muted.
# The contract asks for REGRESSION going forward; this keeps the existing records legible meanwhile.
REOPEN_RE = re.compile(r"\bREGRESSION\b|nawr[oó]t", re.I)
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


def sh(args: List[str], cwd: Optional[str] = None) -> str:
    """Run a command, return trimmed stdout, empty string on any failure.

    Lived in BOTH backlog-collect.py and backlog-archive.py, verbatim, inside the very refactor
    whose stated purpose was that the two "cannot drift apart" — so it moved here (2026-09-18).
    """
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=15)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def main_root(repo_dir: str) -> str:
    """First `git worktree list` entry is ALWAYS the main worktree, even from a linked one."""
    out = sh(["git", "worktree", "list", "--porcelain"], cwd=repo_dir)
    if out.startswith("worktree "):
        return out.splitlines()[0][len("worktree "):]
    return sh(["git", "rev-parse", "--show-toplevel"], cwd=repo_dir) or repo_dir


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
    return bool(_WRAPPED_MARKER_RE.search(body) or _WRAPPED_VERDICT_RE.search(body)
                or _WRAPPED_PHRASE_RE.search(body) or _BARE_MARKER_RE.search(body))


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
        if words:
            return base + "|" + " ".join(words[:8])
        # Degenerate and very common: the path ENDS the text — "no global secureHeaders() middleware
        # (apps/api/src/app.ts)" — so the window after it is empty and EVERY entry naming that file
        # collapses to "app.ts|". Measured collision in tgmcontest: R-9 (no secureHeaders middleware)
        # and R-1 (CORP header too broad) are different findings that shared a key and were reported
        # as a both-files violation. Fall back to the words immediately BEFORE the path, which in this
        # shape are the description itself; resolution prose has already been stripped above, so the
        # key still survives closure.
        before = _WORD_RE.findall(clean[:m.start()].lower())
        if before:
            return base + "|" + " ".join(before[-8:])
        # Both windows empty — a path-only entry. Falling through to "basename|" would re-create the
        # exact collapse this branch exists to prevent (adversarial pass, same review), so key off the
        # whole line instead; it is all the entry has.
        return base + "|" + " ".join(_WORD_RE.findall(clean.lower())[:8])
    return "|" + " ".join(_WORD_RE.findall(clean.lower())[:8])


# `B-70` is a POSITION, not an identity. Measured across the fleet the day the archiver first ran for
# real: `B-1`..`B-9` in codesift-mcp and `B-70`..`B-79` in QuotasMobi each label two entirely
# different entries (open `B-70` is a chart-utils NaN guard, archived `B-70` is an ivfflat rejection
# leak), because a plain counter gets reused every time someone numbers a fresh batch. Keying identity
# off those produced 14 pairs that looked like namespace violations and were not — the same
# false-alarm class A4 guards against, one level down. A descriptive id (`B-rev-sigterm-leak`,
# `B-API-500`, `B-20260913-KANO-...`) carries content and does bridge open→archived, so it stays an
# identity; an ordinal falls back to the content key, which is what distinguishes those entries.
ORDINAL_ID_RE = re.compile(r"^B-\d+$", re.I)


def entry_key(body: str, ident: str = "") -> str:
    """`id:<slug>` for a descriptive B-id, else `fp:<sha1[:12]>` of the signature (see ORDINAL_ID_RE)."""
    if not ident:
        m = BODY_ID_RE.match(body.strip())
        ident = m.group(1) if m else ""
    if ident and not ORDINAL_ID_RE.match(ident):
        return "id:" + ident.lower()
    return "fp:" + hashlib.sha1(normalize_signature(body).encode()).hexdigest()[:12]


# An id this archiver MINTED. Stripping it is what keeps identity stable across archiving: minting
# rewrites the line, so an archived entry's key becomes `id:b-a2026...` while the SAME entry, if it
# reappears in the open file without the id, keys as `fp:<hash>`. Measured consequence: tgm-pulse's
# archive took the same three entries twice and neither the both-files guard nor `verify` saw it,
# because they compared two keys that had stopped describing the same thing.
MINTED_ID_RE = re.compile(r"^B-A\d{8}-[0-9a-f]{6}\s+")


def keys_for(body: str, ident: str = "") -> set:
    """Every key this entry can legitimately be known by: its own, plus the content key it had
    BEFORE an id was minted for it. Comparing sets is what makes archiving idempotent."""
    out = {entry_key(body, ident)}
    stripped = MINTED_ID_RE.sub("", body.strip())
    if stripped != body.strip():
        out.add(entry_key(stripped))
    return out


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
