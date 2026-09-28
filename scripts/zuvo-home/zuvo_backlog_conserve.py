"""WHAT MUST BE TRUE BEFORE EITHER RENAME — the archive's conservation checks, in one place.

Its own module for the reason the other siblings are, and the number is the argument: the aggregate
review added the over-cover refusal below and `backlog-archive.py` went 722 -> 791 raw lines, nine
short of `rules/file-limits.md`'s automatic CQ11 FAIL at 800. Extracting the checks is also the better
seam on its merits: `cmd_archive` decides WHAT moves, `_build_sections` decides where it lands, and
these three decide whether the result is allowed to be written at all. They are the only code here
that may call `sys.exit` on a healthy input.

THE THREE ARE DELIBERATELY NOT REDUNDANT, and the order they were written in is the order of what each
one learned:

  1. `refuse_missing_lines` — every moved line must be present in the new archive text. Proves nothing
     was LOST. Blind to duplication, as its own comment said before this module existed.
  2. `refuse_line_mismatch` — the kept lines plus the moved lines must account for the original.
     Proves the arithmetic. Blind to WHICH entry a line belonged to, so it balances exactly while a
     block carries a neighbour's text away.
  3. `refuse_foreign_entries` — no dropped line may be the first line of an entry nobody selected.
     This is the one that does not trust the boundary rule, and it is the only one that can see
     mis-attribution. It exists because 1 and 2 both PASS on a measured over-cover that archived an
     OPEN entry.

All three exit rather than raise, matching the CLI's contract that a refusal is an exit code and a
message on stderr, and all three run while the lock is held and before anything is renamed.
"""
import os
import sys
from typing import List, Set

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_parse as zb  # noqa: E402  (path must be set before the import)


def refuse_missing_lines(moved: List[str], new_archive: str) -> None:
    """Every moved line must appear in the archive text about to be written.

    Proves nothing was LOST, never that nothing was DUPLICATED — and it is a substring test, so a
    moved line that is a substring of an unrelated archive line satisfies it. Both limits are recorded
    in `B-20260928-IO-PREEXISTING-DATALOSS` item 2, whose fix is to compare against the APPENDED bytes
    with a per-line count; it is deferred there, not forgotten here.
    """
    for ln in moved:
        if ln not in new_archive:
            sys.exit("internal: a moved line is not present in the archive — nothing written")


def refuse_line_mismatch(kept: List[str], lines: List[str], moved: List[str]) -> None:
    """The kept lines plus the moved lines must account for every original line."""
    if len(kept) != len(lines) - len(moved):
        sys.exit("internal: line accounting mismatch — nothing written")


def refuse_foreign_entries(lines: List[str], drop: Set[int],
                           selected: Set[int], interior: Set[int]) -> None:
    """Refuse the whole run when a moved range swallowed an entry that was not selected for it.

    THE ONE CHECK THAT DOES NOT DEPEND ON THE BOUNDARY RULE BEING RIGHT. The two existing conservation
    checks above are both blind to mis-attribution by construction, and their own comment says so: the
    presence check finds every moved line present in the archive, and the line-accounting check balances
    exactly, because a swallowed entry's lines really did move exactly once. So an over-covering block
    passes both while carrying somebody else's OPEN work out of the file.

    Measured (aggregate review, behaviour audit, default gate-off `archive`): a stray ``` inside one
    entry's prose pairs with a LATER entry's code-sample opener, the span between them is stepped over
    as "content", and `- [ ] B-two still OPEN work` is archived — after which `lookup` answers ARCHIVED
    for live work, the exact inverse of the defect this whole change exists to fix. Fleet exposure today
    is zero (399 backlog files, none with an odd per-character fence count), so this is a latent class,
    not a live incident.

    It is enforced HERE rather than inside `entry_block` because the boundary rule cannot decide it. A
    flush-left `# comment` or a `- [ ] sample` inside a fenced block is legitimately content — the suite
    pins both — so "does this span contain something entry-shaped" is not answerable from the markdown
    alone. It IS answerable here, because the caller passes `selected` — the line numbers `classify`
    resolved as chosen for this run — so "a dropped line is the first line of an entry nobody selected"
    is exact rather than inferred. An
    earlier attempt at the `entry_block` heuristic traded this over-cover for a worse under-cover,
    splitting a genuine fenced recipe at its own `#` comment.

    TWO BOUNDS ON WHAT IT SEES, both deliberate and both found by running it:

      * `kinds=(zb.KIND_CHECKBOX,)`, pinned like every other write-path call in this file. The first
        version used `(zb.KIND_CHECKBOX,)` because a swallowed heading is as bad as a swallowed checkbox —
        and the mechanical pin guard immediately failed the run, reporting a THIRD unpinned call in a
        write path. It was right to: "this particular read is harmless because it only ever refuses" is
        exactly the reasoning the guard exists to make unnecessary. The measured hazard (BEHAV-1's
        `- [ ] B-two still OPEN work`) is a checkbox entry, so the pin costs nothing today; a swallowed
        HEADING is reachable only with the gate on, where `heading_candidates` has already refused
        overlapping spans.
      * `interior` — the lines inside a MOVING heading's span. A child entry there travels with its
        parent by design (AC5), so without this the check refuses the very nesting the feature exists
        to support: it did, on the gate-on acceptance fixture, naming a legitimately carried child.

    Fail-closed and before either rename, like the checks above: nothing is written.
    """
    for e in zb.iter_entries("".join(lines), kinds=(zb.KIND_CHECKBOX,)):
        if e.lineno - 1 in drop and e.lineno not in selected and e.lineno not in interior:
            sys.exit(
                "internal: the block being moved contains %s (backlog.md:%d), which was not selected "
                "for archiving — a boundary over-covered into another entry. Nothing written; the two "
                "conservation checks cannot see this, so this refusal is the only signal."
                % (e.ident or e.key, e.lineno))
