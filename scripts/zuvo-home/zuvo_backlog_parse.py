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
from typing import Iterator, NamedTuple, Optional, List, Sequence, Tuple

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
# How much indentation an ATX heading may carry: 0-3 SPACES, per CommonMark. At four the line is an
# INDENTED CODE BLOCK and the hashes are content. Measured defect this closes: with
# "## B-parent" / "    ## B-fake inside a code block" / "- [ ] B-child", the fake line moved `section`
# to 'B-fake inside a code block' AND popped the heading stack, so B-child reported parent_key=None —
# a documented code sample re-parenting the entries after it. A tab counts as four columns and is
# therefore excluded too, which `[ ]{0,3}` gets for free by not matching \t.
# Note the three TIERS this creates, all pinned by tests: 0 spaces = heading, may be an entry;
# 1-3 spaces = heading for SCOPE only (moves `section`, pops the stack), never an entry definition
# (see `_heading_parts`); 4+ spaces or a tab = not a heading at all, touches nothing.
_ATX_INDENT_RE = re.compile(r"^[ ]{0,3}#")
CHECK_LINE_RE = re.compile(r"^[-*]\s*\[[ xX]\]")
_TICKED_RE = re.compile(r"^[-*]\s*\[[xX]\]")
_UNTICKED_RE = re.compile(r"^[-*]\s*\[\s\]")
_TABLE_DONE_RE = re.compile(r"\b(RESOLVED|DONE|CLOSED)\b")

# The dialects a backlog records an entry in; `Entry.kind` says which one a line was written as.
KIND_CHECKBOX, KIND_BULLET, KIND_TABLE, KIND_HEADING = "checkbox", "bullet", "table", "heading"
# Today's tolerant set, EXACTLY — heading entries are opt-in via `kinds=`. `install.sh` globs this
# directory into the machine-global `~/.zuvo/` and `append-runlog` runs `backlog-archive.py archive`
# on every skill run in every repo, so yielding heading entries by DEFAULT would have the archiver
# rewriting tracked files (170-216 marker-carrying open heading entries fleet-wide) on install.
DEFAULT_KINDS = (KIND_CHECKBOX, KIND_BULLET, KIND_TABLE)
_ALL_KINDS = DEFAULT_KINDS + (KIND_HEADING,)

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
    section: str         # nearest enclosing "##" heading, verbatim, or "". For a HEADING entry it is
                         # LEVEL-AWARE: the nearest heading of a STRICTLY LOWER level, never itself
                         # and never a same-level sibling (siblings share one section)
    # Appended LAST with defaults, deliberately: a NamedTuple's field order IS its tuple order, so
    # inserting anywhere above would break every positional construction and tuple unpack.
    kind: str = KIND_CHECKBOX          # the dialect that ADMITTED this line under the requested
                                       # kinds= (most specific first), never one the caller did not
                                       # ask for: CHECKBOX | BULLET | TABLE | HEADING
    end_lineno: int = 0                # last line of the entry; the parser sets it to `lineno`
    parent_key: Optional[str] = None   # key of the nearest enclosing HEADING entry, else None


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


def _last_match_start(pattern: "re.Pattern[str]", text: str) -> int:
    """Start offset of the RIGHTMOST match, or -1. `re` has no reverse search."""
    last = -1
    for m in pattern.finditer(text):
        last = m.start()
    return last


def resolution_marker_pos(body: str) -> int:
    """Rightmost start offset of any resolution marker in `body`, or -1 when there is none.

    The positional form of `has_resolution_marker`, which is defined in terms of it so the two can
    never recognise different marker sets. Position is what makes ORDER decidable: a heading that was
    closed, re-opened, and then genuinely closed again ("— DONE [REGRESSION …] — DONE again") records
    all three facts on one line, and only the offsets say which one is current.
    """
    return max(_last_match_start(p, body) for p in
               (_WRAPPED_MARKER_RE, _WRAPPED_VERDICT_RE, _WRAPPED_PHRASE_RE, _BARE_MARKER_RE))


def has_resolution_marker(body: str) -> bool:
    """True when a resolution marker appears ANYWHERE, not only at the head.

    `is_resolved_inline` deliberately anchors at the start (that is what keeps "the DONE column"
    prose from marking an item resolved). Archiving needs the looser test as a *guard*: an entry
    is only archivable when it is ticked AND says why, and real entries put the marker mid-line
    ("B-GGPD-1 [RECOMMENDED] … conf 62 — DONE b9767b6a5").
    """
    return resolution_marker_pos(body) >= 0


# The bare-marker form with CASE as the discriminator, exactly as `_WRAPPED_VERDICT_RE` above already
# does it and for the same reason: a real recorded verdict is written in caps ("— DONE b9767b6a",
# "— FIXED abc1234"), while the counterexamples are all ordinary lowercase prose.
_CAPS_BARE_MARKER_RE = re.compile(r"(?<!\bnie )\b(?:" + _MARKER_ALT + r")\b")


def strip_ident(body: str) -> str:
    """`body` without its own `B-…` id token, for predicates that must not read the id as content.

    ONLY the id token's own span comes out — not everything up to it. `_ID_PREFIX` deliberately admits
    up to four bracketed tags BEFORE the id, so a leading verdict is inside the match:
    "[FIXED 35e7f18b] B-SQLITE-TRACKED-DB — …" has `m.end()` past the marker, and cutting there would
    discard a genuine resolution and report a closed entry as open. Measured on the fleet: doing it the
    lazy way flipped 5 genuinely-FIXED entries to open.
    """
    m = BODY_ID_RE.match(body)
    return body if not m else body[:m.start(1)] + body[m.end(1):]


def heading_resolution_pos(body: str) -> int:
    """Rightmost resolution-marker offset for a HEADING entry, or -1. Stricter than the guard above.

    WHY A SECOND, STRICTER PREDICATE INSTEAD OF REUSING `resolution_marker_pos`. That one is a
    deliberately LOOSE guard and its docstring says so: an entry is archivable when it is ticked AND
    says why. The tick is the decision; the marker only has to corroborate it, so tolerance there costs
    nothing. A heading has NO TICK, so promoting that guard to the sole status source made every
    tolerance a false "resolved" — in the archivable direction. Measured over 3561 heading entries in
    399 `memory/backlog*.md` files under ~/DEV and ~/projects: 499 read resolved under the loose guard,
    449 under this one. All 50 differences are false positives of the loose guard; none of the 449 is
    new (0 flips the other way), and 15 hand-written forms covering both leading `[FIXED sha]` and
    trailing `— DONE sha` verdicts, plus the reopen-ordering cases, all keep their previous verdict.

    Two tolerances are dropped, each with its own counterexample from the live corpus:

      * THE ID IS NOT CONTENT. Ids are SCREAMING-KEBAB, so `B-RPT-FB-EXPORT-STALE` contains its own
        "verdict" and `## B-20260920-CLOSING-CONVENTION-LEAVES-STALE-OPEN-DUPLICATES` read resolved
        because of the word STALE in its NAME. 33 entries fleet-wide were decided this way, 3 of them
        in this repo's own backlog. `strip_ident` removes the token before the scan.
      * A BARE MARKER MUST BE IN CAPS. `_BARE_MARKER_RE` carries `re.I`, which is right for the guard
        and wrong here: "socket is closed too early on reconnect", "the fixed-width column header",
        "cannot be closed with Esc" and — from this repo's own backlog — "the two oversized functions
        are fixed, the module is not" all read resolved. 8 of 9 realistic open titles did. The wrapped
        forms keep their existing rules, which already encode this discipline.

    `has_resolution_marker` is left exactly as it was: it still guards the ticked-checkbox path, where
    tolerance is correct and where changing it would start refusing to archive real closed entries.
    """
    scan = strip_ident(body)
    return max(_last_match_start(p, scan) for p in
               (_WRAPPED_MARKER_RE, _WRAPPED_VERDICT_RE, _WRAPPED_PHRASE_RE, _CAPS_BARE_MARKER_RE))


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


def _requested_kinds(checkbox_only: bool, kinds: Optional[Sequence[str]]) -> Tuple[str, ...]:
    """Resolve the two selectors into one tuple of kinds.

    `checkbox_only=True` is a PERMANENT documented alias for `kinds=(KIND_CHECKBOX,)`, never a
    deprecation: 7 of the 9 call sites use it and every one is a write/gate path reached through
    `append-runlog`, where a DeprecationWarning on stderr is indistinguishable from a failure.
    An unknown kind raises instead of yielding nothing, because `kinds=("headings",)` returning an
    empty iterator reads as "this file has no heading entries" — a silent false negative in a
    dedup check whose whole job is answering that question. An EMPTY `kinds=()` has exactly that
    failure mode and therefore raises too: a caller that computed its kind list and got nothing
    (a filtered-to-empty list, a mistyped constant that fell out) would otherwise read the empty
    iterator as "no entries of any requested kind" — the same false green, one step earlier.

    `kinds` IS MATERIALIZED ONCE, before anything reads it, because a `Sequence` is what the signature
    asks for but a ONE-SHOT ITERABLE is what a caller passes sooner or later (`kinds=iter(...)`, a
    generator expression filtering a kind list). This function used to scan `kinds` for unknown kinds
    and THEN `tuple(kinds)` it: on a generator the second pass saw an exhausted iterator, returned
    `()`, and the walk yielded NOTHING — measured, with no error at all. That is precisely the false
    "this file has no entries of that kind" the raises below exist to prevent, arriving through the
    argument's TYPE instead of its value.

    A bare `str` is rejected rather than accepted: `kinds="heading"` is a Sequence[str] to the type
    checker and iterates into characters, so it would otherwise fail as
    "unknown kind(s): 'h', 'e', 'a'…" — an error that describes the symptom and hides the mistake.
    """
    if kinds is not None and checkbox_only:
        raise ValueError("pass kinds= or checkbox_only=, not both")
    if kinds is None:
        return (KIND_CHECKBOX,) if checkbox_only else DEFAULT_KINDS
    if isinstance(kinds, str):
        raise ValueError("kinds= takes a sequence of kinds, not the string %r — a bare string "
                         "iterates into characters (did you mean (%r,)?)" % (kinds, kinds))
    resolved = tuple(kinds)   # ONCE: every check below reads this, never `kinds` (see docstring)
    if not resolved:
        raise ValueError("kinds= must name at least one kind (known: %s); an empty selection "
                         "would silently yield nothing" % ", ".join(_ALL_KINDS))
    unknown = [k for k in resolved if k not in _ALL_KINDS]
    if unknown:
        raise ValueError("unknown kind(s): %s (known: %s)"
                         % (", ".join(map(repr, unknown)), ", ".join(_ALL_KINDS)))
    return resolved


def _body_kinds(stripped: str) -> Tuple[str, ...]:
    """Every dialect a non-heading line satisfies, most specific first ("" for a non-entry line).

    A checkbox bullet is BOTH checkbox and bullet, which is what makes `DEFAULT_KINDS` reproduce the
    old tolerant predicate (`is_item or is_table`) while checkbox mode keeps the narrower `is_check`.

    THE OVERLAP IS DELIBERATE AND SELECTION IS BY SATISFACTION, not by a "primary" dialect:
    `- [ ] x` IS a markdown bullet, so `kinds=(KIND_BULLET,)` DOES select checkbox lines — asking for
    bullets and getting only the unticked ones would be the surprise, and `kinds=(KIND_CHECKBOX,)`
    already exists for the narrow question. What such an entry REPORTS as its `kind` is the kind that
    admitted it (see `iter_entries`), so a caller never receives a row stamped with a dialect it did
    not ask for; `DEFAULT_KINDS` asks for both and the most specific one (checkbox) wins there.
    One deliberate divergence, pinned by a test rather than discovered later: `-[x] x` with no space
    after the dash satisfied `is_check` but not `is_item`, so it used to be an entry in checkbox mode
    and not in tolerant mode. It is now an entry in both. Zero such lines exist in either canonical
    backlog file, so the change is inert on the real corpus.
    """
    kinds: List[str] = []
    if CHECK_LINE_RE.match(stripped):
        kinds.append(KIND_CHECKBOX)
    if stripped.startswith("- ") or stripped.startswith("* "):
        kinds.append(KIND_BULLET)
    elif stripped.startswith("|") and ID_RE.search(stripped):
        kinds.append(KIND_TABLE)
    return tuple(kinds)


def _body_status(stripped: str, kinds: Tuple[str, ...], section_done: bool) -> str:
    """open/done for a non-heading line: its own checkbox first, then a table's verdict column,
    then the enclosing section's heading.

    NO REOPEN_RE HERE, deliberately. This path's status source is the TICK — an explicit human act —
    so "- [x] B-x — DONE [REGRESSION …]" stays `done` and "- [ ] …" stays `open` whatever the prose
    says. `_heading_entry` consults `REOPEN_RE` because a heading has no tick and its status is
    DERIVED from the marker text, which a re-open note genuinely contradicts. Different sources, not
    an inconsistency: do not "harmonise" the two by adding the guard here — that changes `classify()`
    and archiving behaviour for every ticked entry in every checkout.
    """
    if _TICKED_RE.match(stripped):
        return "done"
    if _UNTICKED_RE.match(stripped):
        return "open"
    if KIND_TABLE in kinds:
        return "done" if _TABLE_DONE_RE.search(stripped) else "open"
    return "done" if section_done else "open"


def _heading_parts(line: str) -> Optional[Tuple[int, str, bool]]:
    """`(level, text, indented)` for a real ATX heading, else None — THE single normalization.

    ONE function, because there used to be two and they disagreed. `iter_entries` matched
    `HEADING_RE` against `line.strip()` when updating `section`, while `_heading_entry` gated on
    `line.startswith("#")` — so `  ## Plain title` (a heading under CommonMark, which allows up to
    three leading spaces) moved `section` out of an enclosing heading entry's scope and left that
    entry on the heading stack. The next `- [ ] B-child` then reported a `parent_key` pointing at a
    heading the document had already closed, while its `section` said otherwise: two fields of the
    same row disagreeing about where the row lives. Every caller now asks this one function, so the
    two normalizations cannot drift apart again.

    `indented` is reported, not acted on: an indented heading is a REAL heading for scope (it moves
    `section`, so it must also pop the stack) but never an entry DEFINITION — `  ## B-x` inside a
    list is prose about an entry. `line` is already `rstrip()`ped by the caller, so
    `line != stripped` is exactly "has leading whitespace".

    That tolerance is BOUNDED at three spaces (`_ATX_INDENT_RE`): at four the line is an indented
    code block and not a heading in any sense, so this returns None and the line touches nothing.
    Without the bound an ATX-looking line inside a fenced-or-indented code sample moved `section`
    and popped the heading stack — measured, and the reason `indented` can only ever mean 1-3.
    """
    stripped = line.strip()
    if _ATX_INDENT_RE.match(line) is None:
        return None
    h = HEADING_RE.match(stripped)
    if h is None:
        return None
    return len(stripped) - len(stripped.lstrip("#")), h.group(1).strip(), line != stripped


def _heading_entry(lineno: int, raw: str, line: str, parent_section: str,
                   stack: List[Tuple[int, str]]) -> Optional[Entry]:
    """The Entry for an id-shaped heading, else None — and keep `stack`, the enclosing
    heading-entry chain that feeds `parent_key`, current either way.

    ID-ANCHORED on purpose: a heading at any level is an entry iff `BODY_ID_RE` matches the
    post-hash text, so the rule can only ever UNDER-cover. 20 of the 102 headings in the canonical
    backlog are entry-shaped without an id; they stay non-entries and are reported upstream rather
    than guessed at. `body` comes from `HEADING_RE`, never from `body_of()`/`CHECKBOX_RE`: those are
    a no-op on a heading TODAY, and relying on a no-op is how the next change to `CHECKBOX_RE` would
    break this silently. Status comes from `has_resolution_marker` because the marker sits at the END
    of these lines ("## B-x — DONE") — measured 24 of 82, against 0 for the head-anchored
    `is_resolved_inline`; `DONE_SECTION` is prefix-anchored too, which IS the original defect.
    An INDENTED heading is never an entry: it still updates `section` AND pops the stack (it is a
    real heading for scope — see `_heading_parts`), but `  ## B-x` inside a list is prose about an
    entry, not its definition.

    A RE-OPEN MARKER OUTRANKS THE RESOLUTION MARKER. `has_resolution_marker` is pre-existing and
    was only ever an archive-honesty GUARD layered on top of a checkbox (`backlog-archive.py`:
    "ticked AND says why"), never a status primitive — and `_WRAPPED_MARKER_RE` deliberately counts
    "[REGRESSION …]" as a resolution CLAUSE, because for that guard's question a regression note is
    a recorded resolution. Promoting the guard to the SOLE status source for headings imported that
    blindness into status: "## B-x — DONE [REGRESSION 2026-09-27: broke again]" read as `done`, i.e.
    archivable, although `backlog-protocol.md` documents exactly that form as a re-open and
    `REOPEN_RE` exists for it. The BULLET path does not have this defect — on the identical body it
    answers `open`, because its status comes from the checkbox and `is_resolved_inline` is
    head-anchored — so the heading path must not disagree with it about the same text.
    "## B-x — DONE" (no re-open marker) stays `done`: 24 of the 84 id-shaped headings in the
    canonical backlog are that shape, and 0 carry a re-open marker, so this is inert on the real
    corpus and guards the documented path.

    BUT THE LAST MARKER WINS, so the outranking is POSITIONAL and not an existence test. A bare
    `REOPEN_RE.search(body)` has no sense of order, and a heading that was closed, re-opened, and then
    genuinely re-resolved — "— DONE [REGRESSION 2026-09-28: broke] — DONE again 2026-09-28" — was
    forced `open` for ever: the entry can never be archived again, which is the mirror of the defect
    above and just as silent. The resolution side already reads positionally (the marker sits at the
    END of these lines), so the re-open side must too. Compared as rightmost-start offsets: a re-open
    marker suppresses `done` only when it is the LATER of the two. "[REGRESSION …]" alone still reads
    `open`, because `_WRAPPED_MARKER_RE` matches the clause from its opening bracket and the word
    inside it therefore always starts later.

    TWO STATUS SOURCES, ONE REOPEN GUARD — do not "harmonise" them. A checkbox entry's status is its
    TICK (`_body_status`): an explicit human act, which a later "[REGRESSION …]" in the same text does
    not undo, so `- [x] B-x — DONE [REGRESSION …]` is still `done` and the archiver is right to move
    it. A heading has no tick, so its status is DERIVED from the marker text — which is exactly why it
    needs re-open awareness that the checkbox path does not. The asymmetry is the two sources, not a
    missing guard; adding the guard to the ticked path would change `classify()` and archiving across
    every checkout (tracked as its own backlog item).

    THE STACK IS POPPED FOR EVERY REAL HEADING, entry-shaped or not, and BEFORE the `BODY_ID_RE`
    gate — a plain `## Some section` genuinely CLOSES the scope of an enclosing heading entry at or
    below its level, so `## B-parent` / `## Plain title` / `- [ ] B-child` must leave the child with
    `parent_key=None`. Popping only for id-shaped headings would under-pop and hand that child to
    `B-parent`, which is not where the document puts it. A DEEPER plain heading (`### Plain sub`)
    pops nothing and therefore keeps the child inside `B-parent` — also what the document says.
    But the pop happens only for lines `HEADING_RE` actually accepts: `####### x` (past the level
    range) and `##x` (no space after the hashes) are paragraphs in CommonMark, not level-7/level-2
    headings, so they close no scope and must leave the stack alone. That is why the
    `_heading_parts` check sits ABOVE the pop and the `m is None` check BELOW it.
    """
    parts = _heading_parts(line)
    if parts is None:
        return None
    level, body, indented = parts
    while stack and stack[-1][0] >= level:
        stack.pop()
    parent_key = stack[-1][1] if stack else None
    if indented:
        return None
    m = BODY_ID_RE.match(body)
    if m is None:
        return None
    # A TEMPLATE heading is not an entry. The check is REPEATED here, not inherited: `TEMPLATE_RE`'s
    # other call site is the non-heading branch of `_iter_entries`, which this function never reaches,
    # so "## B-tpl fingerprint | source-task" — matching BOTH `TEMPLATE_RE` and `BODY_ID_RE`
    # (measured) — was admitted as a real entry and the archiver would file the format documentation
    # itself. Id-anchoring exists so this rule may only UNDER-cover; admitting a template over-covers.
    # AFTER the pop and BEFORE the push, exactly like the `indented` return above, and for the same
    # reason: a template heading is still a REAL heading for scope, never a DEFINITION — the split the
    # non-heading branch already makes, where `TEMPLATE_RE` skips the entry and not the bookkeeping.
    if TEMPLATE_RE.search(body):
        return None
    key = entry_key(body, m.group(1))
    stack.append((level, key))
    # `heading_resolution_pos`, NOT `resolution_marker_pos`: a heading has no tick, so this predicate
    # is the whole decision rather than a guard corroborating one, and the guard's deliberate tolerance
    # becomes a false "resolved" in the archivable direction. See that function's docstring for the
    # corpus measurement. REOPEN is compared on the same id-stripped text so the two offsets are in one
    # coordinate system — comparing a stripped offset against an unstripped one would be off by the
    # length of the id whenever the id sits before the marker, which is the normal layout.
    scan = strip_ident(body)
    resolved_at = heading_resolution_pos(body)
    reopened_at = _last_match_start(REOPEN_RE, scan)
    done = resolved_at >= 0 and reopened_at < resolved_at
    return Entry(lineno=lineno, raw=raw, body=body,
                 status="done" if done else "open",
                 ident=m.group(1), key=key, section=parent_section,
                 kind=KIND_HEADING, end_lineno=lineno, parent_key=parent_key)


def iter_entries(text: str, *, checkbox_only: bool = False,
                 kinds: Optional[Sequence[str]] = None) -> Iterator[Entry]:
    """Yield entries of the requested dialects, with their enclosing `##` heading.

    `checkbox_only` is what the archive tooling uses: membership of the archive namespace is about
    real entries, and the archive also contains prose headers and notes. The fleet collector keeps
    the tolerant behaviour (bullets, tables, `- [B-N] text`) so it does not drop a dialect.
    `kinds=` is the explicit form of the same question and the only way to ask for heading entries;
    `DEFAULT_KINDS` is the tolerant set exactly, so no existing caller changes behaviour.

    `end_lineno` is the entry's own line. A heading block's real extent is level-and-sibling aware
    and belongs to the archiver that rewrites the file, not to the parser.

    NOT a generator function, deliberately: `kinds=` is validated EAGERLY here and the iteration
    happens in `_iter_entries`. As one `def` with `yield` in it, the whole body — including
    `_requested_kinds` — ran on the first `next()`, so `iter_entries(text, kinds=())` returned
    cleanly and raised only wherever the caller finally iterated it. A ValueError surfacing in a
    different function from the bad argument is the diagnosis cost this validation exists to avoid,
    and a caller that builds the iterator and hands it on never sees it at all.

    RAISES ValueError AT CALL TIME, not on first iteration — a bad `kinds=`/`checkbox_only=`
    combination, an empty selection, a bare string, or an unknown kind all raise from THIS call, before
    any line of `text` is read. The timing change is the POINT of the split, not a side effect: code
    that wrapped `list(iter_entries(...))` in `except ValueError` still catches it, while code that
    only guarded the iteration site was relying on the deferred raise that was the defect. `kinds=`
    may be any iterable, including a one-shot one; it is materialized once inside `_requested_kinds`.
    """
    return _iter_entries(text, _requested_kinds(checkbox_only, kinds))


class _Scope(NamedTuple):
    """The walk's heading state, threaded through `_heading_line` so `_iter_entries` stays readable.

    A NamedTuple and not four locals because the heading branch UPDATES `section`/`section_done` and
    a helper cannot rebind a caller's locals. The two lists are mutated in place (that is their whole
    job — `stack` must stay current in every mode), so only the two scalars travel by value.
    """

    section: str
    section_done: bool
    stack: List[Tuple[int, str]]        # (heading level, key) of the enclosing heading ENTRIES
    sec_stack: List[Tuple[int, str]]    # (heading level, text) of EVERY enclosing heading


def _heading_line(lineno: int, raw: str, line: str, want: Tuple[str, ...],
                  sc: _Scope) -> Tuple[_Scope, Optional[Entry]]:
    """Fold one `#`-leading line into the scope state; return the new state and any Entry it yields.

    Extracted from `_iter_entries`, which the eager-validation split left over the 30-line
    private-helper limit in `rules/file-limits.md` (it had been compliant as the 50-line PUBLIC
    `iter_entries`, and the rename to a private name moved the threshold without anyone re-checking).
    The split is along the branch boundary the code already had, so no logic changed.

    The `_ATX_INDENT_RE` guard (see that constant) returns the scope UNCHANGED for a 4+-indented line:
    an indented code block must touch nothing — not `section`, not `section_done`, not either stack.
    It is repeated here rather than left to `_heading_parts` because `parts is None` has a second,
    different meaning (`##x`, `####### x`: paragraphs that DO still reach the
    `DONE_SECTION`/`OPEN_SECTION` checks below, pre-existing), and conflating the two would change
    those paragraphs' behaviour as a side effect.

    `parent_section` is LEVEL-AWARE, and `section` is not: they answer different questions. `section`
    is "the heading this line sits under", verbatim and unchanged — what every non-heading row has
    always reported. `parent_section` is a heading ENTRY's own `section`, which must be its nearest
    ENCLOSING heading of a LOWER level. Taking the previous heading text (`parent_section = section`)
    made same-level siblings chain into each other: `## Open` / `## B-alpha` / `## B-beta` gave
    B-beta `section='B-alpha'` instead of 'Open', so a flat list of sibling entries reported a
    nesting the document does not contain. `parent_key` was already level-aware; only this was not.

    `_heading_entry` is called AFTER the section/section_done update, so children's `section`
    semantics are untouched and a heading entry's own `section` is its parent — and it is called even
    when headings are not WANTED, because `stack` must stay current in every mode or `parent_key`
    would depend on which kinds the caller asked for.
    """
    if _ATX_INDENT_RE.match(line) is None:
        return sc, None
    section, section_done = sc.section, sc.section_done
    parts = _heading_parts(line)
    if parts is not None:
        level, text_h, _indented = parts
        while sc.sec_stack and sc.sec_stack[-1][0] >= level:
            sc.sec_stack.pop()
        parent_section = sc.sec_stack[-1][1] if sc.sec_stack else ""
        sc.sec_stack.append((level, text_h))
        section = text_h
    else:
        parent_section = section
    if DONE_SECTION.match(line.strip()):
        section_done = True
    elif OPEN_SECTION.match(line.strip()):
        section_done = False
    entry = _heading_entry(lineno, raw, line, parent_section, sc.stack)
    if entry is not None and KIND_HEADING not in want:
        entry = None
    return sc._replace(section=section, section_done=section_done), entry


def _iter_entries(text: str, want: Tuple[str, ...]) -> Iterator[Entry]:
    """The walk itself. See `iter_entries` — split out only so `kinds=` validation is eager."""
    sc = _Scope(section="", section_done=False, stack=[], sec_stack=[])
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            sc, entry = _heading_line(lineno, raw, line, want, sc)
            if entry is not None:
                yield entry
            continue

        stripped = line.strip()
        kinds_here = _body_kinds(stripped)
        # The kind that ADMITTED the line, most specific first — never `kinds_here[0]`, which would
        # stamp a checkbox line `kind="checkbox"` even when the caller asked only for bullets and
        # hand back a row of a dialect it did not request. Under `DEFAULT_KINDS` both are wanted, so
        # a checkbox still reports "checkbox" and the H10 invariance is untouched.
        admitted = next((k for k in kinds_here if k in want), None)
        if admitted is None:
            continue
        if KIND_TABLE in kinds_here and set(stripped.replace("|", "").strip()) <= set("-: "):
            continue
        status = _body_status(stripped, kinds_here, sc.section_done)
        body = body_of(stripped)
        if TEMPLATE_RE.search(body):
            continue
        if status == "open" and is_resolved_inline(body):
            status = "done"
        ident = definition_id(stripped)
        yield Entry(lineno=lineno, raw=raw, body=body, status=status, ident=ident,
                    key=entry_key(body, ident), section=sc.section, kind=admitted,
                    end_lineno=lineno, parent_key=sc.stack[-1][1] if sc.stack else None)


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
