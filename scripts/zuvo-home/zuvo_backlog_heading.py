"""WHICH heading entries the archiver may take, and WHEN. Imported by backlog-archive.py; not a
script, no shebang, no executable bit.

Its own module for the same two reasons `zuvo_backlog_block.py` is one. backlog-archive.py measured
850 raw lines with this policy inlined — past `rules/file-limits.md`'s automatic CQ11 FAIL at 2x the
400-line Python default, the same line it had to be rescued from when the block boundary landed. And
this is ONE cohesive concern: the env gate, the open-follow-up rule and the candidate selection are
three halves of a single policy, so a test that mutates the policy mutates one file. The underscore in
the name is load-bearing exactly as there: `install.sh` flattens `scripts/zuvo-home/*` into `~/.zuvo/`,
so a plain same-directory import resolves identically in the checkout and in the flattened layout,
while a hyphenated name would force a dynamic importlib load that mypy cannot see through. `sys.path`
is the IMPORTER's job — every consumer already does
`sys.path.insert(0, dirname(realpath(__file__)))` before importing any of these siblings.

THE GATE IS WHY THE MODULE EXISTS, so it is stated once here and asserted mechanically in
`tests/hooks/test-backlog-headings.sh`: this file holds the ONLY `iter_entries` call in the archiver's
module family that may ask for `KIND_HEADING`, every other call in the family pins
`kinds=(zb.KIND_CHECKBOX,)` at its own call site, and this one returns before it reads the text unless
`ZUVO_BACKLOG_HEADING_ARCHIVE` is exactly "1". `install.sh` globs this directory into the
machine-global `~/.zuvo/` and `append-runlog` runs `backlog-archive.py archive --repo "$PWD"` at the
end of every skill run in every repo — 170-216 marker-carrying open heading entries exist fleet-wide,
so an ungated version would rewrite tracked files, under `Lock`, in 88 checkouts the moment it
installed. That is the whole reason the remedy for D3 ships switched off.
"""
import os
import re
from typing import Dict, FrozenSet, List, NamedTuple, Optional, Tuple

import zuvo_backlog_block as zbb
import zuvo_backlog_parse as zb
from zuvo_backlog_block import entry_block, with_span

# An ENV VAR and not a `--heading` flag: a flag an agent can type is not an escape a human attributes
# (the 2026-08 `ship --fast` lesson), and the default this protects is fleet-wide rather than per-run.
HEADING_ARCHIVE_ENV = "ZUVO_BACKLOG_HEADING_ARCHIVE"
# WHAT COUNTS AS A CHILD: an INDENTED bullet. Flush-left is a SIBLING and ends the block
# (`zuvo_backlog_block._block_ends_at`), so a column-0 anchor here would count the independent entries
# that follow a heading as its own children.
_CHILD_RE = re.compile(r"^[ \t]+[-*]")
# WHAT COUNTS AS OPEN: an unticked box in ANY of its spellings, ANYWHERE in the child's line.
#
# Both halves are measured corrections, and both move in the direction that HOLDS rather than archives.
# `\[\s\]` required exactly ONE whitespace character, so `- [  ]` and `- []` read as "no open child"
# and a resolved parent archived over live follow-ups — the hold rule failing OPEN. And anchoring the
# box at the child's head missed `- [x] … fixed | [ ] OPEN follow-up: add a test` (the shape
# test-backlog-archive-dedup.sh's A7 fixture uses), which the CHECKBOX hold path holds on its
# `"[ ]" in e.body` substring test — so the same child got different verdicts depending on which
# dialect found it.
#
# THE RELATION TO THE CHECKBOX PATH IS A SUPERSET, asserted as such (H23/F3) rather than shared as a
# call: `classify`'s `"[ ]" in e.body` cannot change, because that is the fleet-wide default path and
# AC4′ pins it byte-for-byte. A superset can never hold LESS than the checkbox path would, which is
# what stops the two from drifting in the direction that loses work.
_OPEN_BOX_RE = re.compile(r"\[[ \t]*\]")


def heading_archive_enabled() -> bool:
    """Exactly "1", never a truthy string. An inherited `ZUVO_BACKLOG_HEADING_ARCHIVE=0` must read as
    OFF: a gate on a write path that runs in every repo is not the place for a tolerant parse."""
    return os.environ.get(HEADING_ARCHIVE_ENV, "") == "1"


def is_open_child(line: str) -> bool:
    """Is this line an indented child carrying an open follow-up? See the two constants above."""
    return bool(_CHILD_RE.match(line) and _OPEN_BOX_RE.search(line))


def _fence_spans(lines: List[str]) -> Dict[int, int]:
    """The block module's DOCUMENT-WIDE fence pairing, never a second detector.

    `entry_block` steps over a closed fence whole, so a checkbox in a documentation sample is content
    for the boundary rule; two notions of "code block" over one document is the `LOOKUP_KINDS` defect
    shape. This used to ask `_fence_close` per candidate line, which inherited the same
    start-dependent pairing bug the aggregate review found in `_scan_to_boundary`: a marker already
    consumed as a closer could be handed back as an opener, so with an odd number of same-character
    markers `open_children` could step over a live `- [ ] B-…` child and report a resolved parent as
    having none — i.e. release it for archiving with its open follow-ups inside. `closed_fence_spans`
    is now the one answer both modules read. An UNCLOSED fence still hides nothing —
    `closed_fence_spans` documents why that deviates from CommonMark on purpose.
    """
    return zbb.closed_fence_spans(lines)


def open_children(lines: List[str], e: zb.Entry, end: Optional[int] = None) -> int:
    """How many open follow-ups sit inside this entry's BLOCK.

    `classify` holds back a resolved checkbox whose own text carries a live `[ ]`, because the open
    follow-up would go out of sight with its resolved parent. A heading's `body` is just its own line,
    so that test sees nothing for a heading and the same rule has to be measured where a heading's
    children actually live: inside its block. `end` is the block end when the caller has already
    measured it (`with_span` does), so the same `entry_block` walk is not repeated per candidate.
    """
    stop = entry_block(lines, e.lineno - 1) if end is None else end
    fences = _fence_spans(lines)
    i, n = e.lineno, 0
    while i < stop:
        close = fences.get(i)
        if close is not None:
            i = close + 1                       # a CLOSED fence is content, not structure
            continue
        if is_open_child(lines[i]):
            n += 1
        i += 1
    return n


class HeadingPlan(NamedTuple):
    """Everything the GATED heading walk knows and the checkbox walk cannot. All empty/zero with the
    gate off, which is what makes every line in `classify` that reads it inert by construction.

    `total` and `staying` exist because two CHECKBOX-ONLY numbers in backlog-archive.py are wrong once
    headings can move, and both of those call sites pin `kinds=(zb.KIND_CHECKBOX,)` and must keep
    doing so: `cmd_status`'s entry total (its `still_open` arithmetic subtracts heading entries it
    never counted) and `cmd_archive`'s `staying` set (an id that names an OPEN heading has to be
    protected, or the same id lands in both files — and `cmd_verify` cannot see that, because it is
    pinned checkbox-only on BOTH sides, so it is a silent namespace split rather than a blocked run).
    """

    moving: List[Tuple[int, zb.Entry]]       # (lineno, spanned entry) for each heading that moves
    held: List[str]                          # human labels for the ones held back, with their counts
    spans: List[Tuple[int, int]]             # 1-based inclusive spans of EVERY candidate, held or not
    total: int                               # heading ENTRIES in the file, moving or not
    staying: FrozenSet[str]                  # keys of heading entries that do NOT leave the file


def heading_candidates(text: str, lines: List[str]) -> HeadingPlan:
    """The plan above — EMPTY when the env gate is off, before anything reads `text`.

    THE ONE env-gated `iter_entries` call in the module family. The other seven — all of them in
    backlog-archive.py, on its write and gate paths — pin `kinds=(zb.KIND_CHECKBOX,)` unconditionally
    at their own call site, and `tests/hooks/test-backlog-headings.sh` (H14, H19c) asserts that split
    mechanically over every `zuvo_backlog_*.py` that imports the parser: seven pins plus exactly one
    gated site, so neither a second gate nor an ungated heading request can join quietly.

    A heading's status is DERIVED from its resolution marker, so a `done` heading always carries one
    and there is no "ticked without a recorded reason" group for it to fall into.

    NESTING, both directions. A done heading INSIDE another resolved heading's block is skipped: it
    travels with that parent when the parent moves, and waits with it when the parent is held. Left in
    the list it would be appended a second time inside its own parent's block — which
    `cmd_archive`'s conservation check cannot see, because that check tests PRESENCE (`if ln not in
    new_archive`) and not multiplicity. The third return value carries the spans of every candidate,
    moving or held, for the same reason one level down: a ticked CHECKBOX inside a resolved heading's
    block must not move on its own either.
    """
    moving: List[Tuple[int, zb.Entry]] = []
    held: List[str] = []
    spans: List[Tuple[int, int]] = []
    if not heading_archive_enabled():
        return HeadingPlan(moving, held, spans, 0, frozenset())
    ents = list(zb.iter_entries(text, kinds=(zb.KIND_HEADING,)))
    still_open = [e.lineno for e in ents if e.status != "done"]
    outer_end = 0
    for e in ents:
        if e.status != "done" or e.lineno <= outer_end:
            continue
        e = with_span(lines, e)
        outer_end = e.end_lineno
        spans.append((e.lineno, e.end_lineno))
        # An open heading entry nested in this block is the same loss as an open `[ ]` child — it
        # would go out of sight with its resolved parent — so it holds the parent back too. Counted
        # separately from `child_open` because they are two shapes of one rule, and the numbers are
        # what make a HELD line actionable.
        inner = [n for n in still_open if e.lineno < n <= e.end_lineno]
        n_open = open_children(lines, e, e.end_lineno)
        if n_open or inner:
            held.append("%s (child_open=%d, open heading(s) inside=%d)"
                        % (e.ident or e.key, n_open, len(inner)))
            continue
        moving.append((e.lineno, e))
    # Per ENTRY and never as a set difference: two headings can share one key (a resolved copy and an
    # open restatement of the same id), and subtracting the movers' keys would then drop the open
    # one's protection along with them — the case this exists for.
    # Hoisted: inside the comprehension this rebuilt the span list once per entry (CQ17, from the
    # aggregate review's CQ audit). Unmeasurable at 91 headings and quadratic at fleet scale.
    moving_spans = _moving_spans(moving)
    staying = frozenset(e.key for e in ents
                        if not any(s <= e.lineno <= en for s, en in moving_spans))
    return HeadingPlan(moving, held, spans, total=len(ents), staying=staying)


def _moving_spans(moving: List[Tuple[int, zb.Entry]]) -> List[Tuple[int, int]]:
    """Spans of the entries that LEAVE the file, which is what decides whether anything inside them
    leaves with them. Separate from `HeadingPlan.spans` (which covers held candidates too) because
    the two answer different questions and one list serving both was how `staying` first went wrong."""
    return [(e.lineno, e.end_lineno) for _, e in moving]
