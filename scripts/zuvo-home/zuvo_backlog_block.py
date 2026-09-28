"""Where an entry's BLOCK ends. Imported by backlog-archive.py; not a script, no shebang.

It lives beside the parser rather than inside it because the two answer different questions: the
parser says which LINES are entries, this module says how far each one's body reaches, and the second
answer belongs to the file that rewrites the backlog (see `iter_entries`' own note on `end_lineno`).
It left backlog-archive.py because that module crossed 800 raw lines — `rules/file-limits.md`'s
automatic CQ11 FAIL at 2x the 400-line Python default — the moment the level-and-sibling rule landed.
One cohesive concern, moved whole; the io/command split that `cmd_archive` still needs is a separate
piece of work and this does not pre-empt it.

The underscore in the name is load-bearing, exactly as in `zuvo_backlog_parse`: `install.sh` flattens
`scripts/zuvo-home/*` into `~/.zuvo/`, and a plain same-directory `import zuvo_backlog_block` then
resolves identically in the checkout and in the flattened layout, while a hyphenated name would force
a dynamic importlib load that mypy cannot see through. `sys.path` is the IMPORTER's job — every
consumer already does `sys.path.insert(0, dirname(realpath(__file__)))` before importing either
module, which is why there is no path manipulation here.

`Entry.end_lineno` AS THE PARSER SETS IT IS THE ENTRY'S OWN LINE, NOT THE END OF ITS BLOCK. Measured:
a heading entry at line 1 whose body runs to line 3 comes out of `iter_entries` with `end_lineno=1`,
and the same holds for a checkbox entry with continuation lines. The parser does that deliberately —
a block's extent is level-and-sibling aware and belongs to the file that rewrites the backlog — but it
means TWO values could answer "where does this entry end", which is the `LOOKUP_KINDS` defect shape.
`with_span` below is the ONE producer, `backlog-archive.py` routes every entry that leaves a function
through it, and the only deliberate exception is `cmd_index` (reasoned at that call site: the index
TSV has no span column). Read `end_lineno` off a raw parser Entry and you are reading the wrong number.

UNDER-COVER, recorded together because they are the same choice made twice: a TAB-indented `- [ ] …`
does not terminate a heading block (the sibling rule is column-0, `zb.CHECK_LINE_RE`), so it counts as
a child; and 6 of the fleet's heading blocks terminate on a flush-left checkbox that carries no `B-`
id and is really the heading's own child (`tgm-survey-platform` x3, `QuotasMobi` x2,
`data-lab-wt-exportpoll` x1, measured 2026-09-28). Both leave a line attributed to a SMALLER entry
than the document intends, never to a larger one — the direction a rule whose callers rewrite tracked
files is allowed to be wrong in.
"""
import re
from typing import Dict, List, Optional

import zuvo_backlog_parse as zb

# THE BOUNDARY RULE, in three constants and two helpers rather than one loop: each half of it can
# then be reverted ON ITS OWN by tests/hooks/test-backlog-headings.sh (H18b), which is how a rule the
# archiver already got wrong once earns the right to be believed.
# 0-3 SPACES, the same tier rule `_heading_parts` applies to an ATX heading: at four columns the line
# is an indented code line and its backticks are content, so it can neither open nor close a fence.
# The MARKER is captured because a `~~~` line must not close a ``` fence — CommonMark closes a fenced
# block only on the same character.
#
# Both properties are fixes to a PRE-EXISTING flaw, not to a regression of this rewrite: the
# `re.match(r"^\s*(```|~~~)", ln)` toggle that the heading rule replaced (committed at 16b5df07) took
# any indentation and either marker. Measured on that inherited detector — a 4-space "```" opened a
# fence that hid the next flush-left `- [ ]` entry, and a `~~~` inside a ``` sample closed it early so
# a `#` comment in the same sample terminated the block. Fixed here because this function was being
# rewritten anyway; the third inherited flaw is in `_fence_close`.
_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
# The LEGACY terminators, unchanged and used ONLY for a bullet-shaped start entry: a `- [ ] …` entry
# ends at the next flush-left bullet or heading, which is what the file's checkbox dialect means and
# what every write path has measured against since this function was written.
_BULLET_START_RE = re.compile(r"^[-*]\s")
_FLUSH_HEADING_RE = re.compile(r"^#{1,6}\s")


def _fence_marker(line: str) -> Optional[str]:
    """The fence CHARACTER (`` ` `` or `~`) this line delimits a fenced block with, else None."""
    m = _FENCE_RE.match(line)
    return None if m is None else m.group(1)[0]


def closed_fence_spans(lines: List[str]) -> Dict[int, int]:
    """{opener index -> closer index} for every CLOSED fence, paired left-to-right over the DOCUMENT.

    PAIRING IS A PROPERTY OF THE DOCUMENT, NOT OF WHERE A SCAN BEGAN — which is the bug this function
    exists to remove. `_fence_close` answers "the next line carrying the same fence character", and
    `_scan_to_boundary` used to ask it fresh at every candidate opener. Two consequences, and the second
    is data loss:

      * a marker already consumed as a CLOSER could be handed back as an OPENER to the next question, so
        with an ODD number of same-character markers the whole pairing shifted by one; and
      * the answer then depended on which entry the scan started from, so two entries in one document
        disagreed about where a fenced region was.

    MEASURED end-to-end on the default, gate-off `archive` path: a stray ``` inside one entry's prose
    paired with the OPENER of a later entry's code sample, `_scan_to_boundary` jumped `close + 1` over
    every structural terminator in between, and an OPEN `- [ ] B-two still OPEN work` was moved into
    backlog-done.md — after which `lookup` answered ARCHIVED for live work, the exact inverse of the
    defect this plan exists to fix. Neither conservation check can see it: the presence check finds the
    line present and the count check balances, because every line moved exactly once. Reported by the
    aggregate review's behaviour audit; the module's docstrings asserted the opposite property in three
    places and the suite's own fixture placed its unclosed fence LAST, which is the one arrangement
    where the old pairing happened to be right.

    One forward pass, one state variable: while a fence is open, only its own character can close it,
    and the closing line is consumed. An unclosed fence at the end of the document yields no entry at
    all — a DELIBERATE deviation from CommonMark, where an unclosed fence runs to end of document. It
    is the third pre-existing flaw of the inherited detector: measured on it, one stray ``` in a heading
    block disabled every structural terminator to EOF (`span = 7 of 7`), so the block absorbed later
    `## B-…` and `- [ ] B-…` entries that `iter_entries` still yields separately. That is OVER-cover,
    the one direction this family of rules refuses. Closing is matched on the CHARACTER only, not on
    CommonMark's "at least as long as the opener": a shorter run of the same character ending a longer
    fence is the under-cover direction, at a line that is a fence delimiter either way.

    Fleet cost, measured on the heaviest real backlog (4604 lines, 499 id-shaped headings):
    ~1.4 ms per call, ~0.7 s if recomputed for every entry, which is why `entry_block` computes it once
    and passes it down rather than each helper asking again.
    """
    spans: Dict[int, int] = {}
    open_at: Optional[int] = None
    open_marker: Optional[str] = None
    for i, ln in enumerate(lines):
        marker = _fence_marker(ln)
        if marker is None:
            continue
        if open_at is None:
            open_at, open_marker = i, marker
        elif marker == open_marker:
            spans[open_at] = i
            open_at, open_marker = None, None
    return spans


def _heading_start_level(line: str) -> Optional[int]:
    """The ATX level of `line`, or None when it is not a heading — the PARSER's tier rule, not a copy.

    Delegating to `zb._heading_parts` is the POINT. The three indentation tiers (0 spaces = heading
    and possibly an entry; 1-3 = a heading for SCOPE only; 4+ = an indented code block that touches
    nothing, `_ATX_INDENT_RE`) are a decision of the parser, and `_heading_entry` already pops the
    heading stack by exactly that rule. A second regex here would be a second source of truth about
    where a BLOCK ends versus where a SCOPE ends — the defect class `LOOKUP_KINDS` spells its
    selection out at every call site to avoid. The name is private and read deliberately: the parser
    exposes no public accessor for the tiers, and duplicating them is the worse of the two evils.

    `rstrip("\r\n")` is DEFENSIVE, and the honest reason is narrower than it looks. `_heading_parts`
    derives the level from `line.strip()` and the indent tier from the leading spaces, so neither
    depends on a trailing newline: this function's return value is identical with or without the
    strip, today. What the newline DOES change is the third element `_heading_parts` reports —
    `indented`, computed as `line != line.strip()`, which reads True for every kept-newline line
    (measured: `_heading_parts("## B-x\n")` → `indented=True`). Nothing here reads that element, so the
    strip buys only this: the day a caller starts reading `indented`, or this function starts returning
    it, the input is already in the shape the parser documents. `lines` comes from
    `splitlines(keepends=True)` at every call site, which is why the case can arise at all.
    """
    parts = zb._heading_parts(line.rstrip("\r\n"))
    return None if parts is None else parts[0]


def _block_ends_at(lines: List[str], i: int, level: Optional[int]) -> bool:
    """Is `lines[i]` the first line AFTER the block? `level` is the start entry's heading level, or
    None when the start entry is bullet-shaped.

    The heading rule is LEVEL-AND-SIBLING aware, and needs both halves. Level alone ("the next
    heading of level <= mine") sweeps the independent `- [ ]` entries that follow a heading entry
    into its block — measured on memory/backlog.md, where four open entries sit between the heading
    at 220 and the next `##` eight lines further down. Every line still lands exactly once, so a
    line-level conservation check passes; the defect is MIS-ATTRIBUTION, not loss.

    A SIBLING is a checkbox entry, not any bullet: a heading entry's own continuation is written as
    flush-left `- **Closed:** …` / `- **Fix:** …` bullets (6 of this repo's id-shaped headings and 432
    of tgm-survey-platform's measured as ONE line for exactly that reason). `zb.CHECK_LINE_RE` is
    anchored at column 0, so an INDENTED `  - [ ] …` is a child of the current entry and keeps its
    place inside the block — which is also what stops a parent block from ending inside its own
    sub-entry's body, i.e. from producing a span that CROSSES another entry instead of nesting.
    """
    ln = lines[i]
    if level is None:
        # `zb.CHECK_LINE_RE` as well as `_BULLET_START_RE`, because the two halves of this function
        # disagreed otherwise and the docstring above describes only the heading half. `-[x] B-b` (no
        # space after the dash) IS an entry to the parser — `CHECK_LINE_RE` does not require the space
        # and `_body_kinds` admits the form in both modes — while `_BULLET_START_RE`'s `^[-*]\s` does
        # not match it. So a bullet entry's block ran straight THROUGH such a sibling and `archive`
        # moved it: measured end-to-end on the default, gate-off path, an OPEN `-[ ] B-b` landed in
        # backlog-done.md and `lookup` answered ARCHIVED for live work. Pre-existing (the base loses the
        # same line) and latent (zero such lines fleet-wide across 399 backlog files), but it is a
        # same-file contradiction, and one predicate answering "is this a sibling entry" for both
        # dialects is the fix rather than a second regex to keep in step.
        return bool(_BULLET_START_RE.match(ln) or zb.CHECK_LINE_RE.match(ln)
                    or _FLUSH_HEADING_RE.match(ln))
    lvl = _heading_start_level(ln)
    if lvl is not None and lvl <= level:
        return True
    return bool(zb.CHECK_LINE_RE.match(ln))


def _scan_to_boundary(lines: List[str], start: int, level: Optional[int],
                      spans: Optional[Dict[int, int]] = None) -> int:
    """First index at or after `start + 1` that lies OUTSIDE the block — blank lines not yet trimmed.

    A CLOSED fenced block is stepped over whole: its contents are content, not structure. Without that,
    a recipe like "```\n# restart cleanly before profiling\nsystemctl restart workers\n```" ends the
    entry at the flush-left `#` comment, reproducing the very split `entry_block` exists to prevent
    while both conservation checks pass, because they verify what WAS moved rather than where the
    boundary fell. An UNCLOSED fence is stepped PAST, one line at a time, so the structural terminators
    after it still apply — see `_fence_close` for why, and for the three pre-existing flaws of the
    inherited detector that this and `_FENCE_RE` fix.
    """
    fences = closed_fence_spans(lines) if spans is None else spans
    i = start + 1
    while i < len(lines):
        # `fences.get(i)`, NOT a fresh per-opener scan: pairing is decided once for the whole document,
        # so a marker already consumed as a CLOSER cannot be handed back as an OPENER here. That is what
        # stops a stray marker in one entry from pairing with a later entry's code sample and jumping
        # this loop over every structural terminator in between — see `closed_fence_spans`, which
        # carries the measured data-loss reproduction.
        close = fences.get(i)
        if close is not None:
            i = close + 1
        elif _block_ends_at(lines, i, level):
            break
        else:
            i += 1
    return i


def entry_block(lines: List[str], start: int) -> int:
    """Index one past the END of the entry that begins at `lines[start]`.

    An entry is NOT one line. Measured on a real archive: tgm-pulse's entries run 30+ lines each
    (continuation prose, file lists, recipes), and moving only the bullet line left the rest orphaned in
    the open backlog — the entry split across two files, with the byte-conservation check passing
    throughout because every line still existed SOMEWHERE. Conservation is asserted per ENTRY for that
    reason. A HEADING entry ends at the next heading of level <= its own or at the next flush-left
    CHECKBOX entry (`_block_ends_at`); a bullet-shaped one keeps the older rule exactly; trailing blank
    lines stay behind as separators, because they are the file's layout and not the entry's.

    RAISES IndexError on an out-of-range `start`, naming the index and the length. Unreachable from the
    three call sites today (each derives the index from `iter_entries` or guards it), and it stays a
    raise rather than a guard returning `start` or `start + 1`: an empty or one-line span for a line
    that does not exist is a wrong ANSWER, and every consumer here slices or DELETES the range.
    """
    if not 0 <= start < len(lines):
        raise IndexError(f"entry_block: start {start} outside 0..{len(lines) - 1} "
                         f"({len(lines)} line(s)) — the caller's line number does not match this text")
    level = _heading_start_level(lines[start])
    i = _scan_to_boundary(lines, start, level, closed_fence_spans(lines))
    while i - 1 > start and not lines[i - 1].strip():
        i -= 1
    return i


def with_span(lines: List[str], e: zb.Entry) -> zb.Entry:
    """`e` with `end_lineno` MEASURED by `entry_block` instead of left at the parser's default.

    `entry_block` returns the index one past the end, 0-based, which is the same number as the
    1-based INCLUSIVE last line. The conversion is a no-op and this sentence is its proof, because a
    reader who assumes otherwise adds an off-by-one that only a multi-line entry can reveal.

    THE ONLY PRODUCER of a meaningful `end_lineno`, for both dialects — the module docstring says what
    the parser's default is and why it is not this. Every function in `backlog-archive.py` whose
    entries leave it (`find`, `classify`, `undeclared_pairs`) routes them through here, so no caller
    can read a raw parser value by accident; `cmd_archive`/`cmd_drop_stale` call `entry_block` on the
    same lines, which is the same number. `cmd_index` is the one deliberate exception and says so at
    its own call site: the index TSV has no span column, and widening that format is a fleet-wide
    change (`~/.zuvo/` helpers in every repo read `.backlog-index.tsv`).
    """
    return e._replace(end_lineno=entry_block(lines, e.lineno - 1))
