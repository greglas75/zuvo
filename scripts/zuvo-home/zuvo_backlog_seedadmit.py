"""CONTROL (d)'s ADMISSIBILITY: can the dispatched tree still support a seed's expected verdict?

Extracted from `zuvo_backlog_seeds.py` for the 400-line reason rules/file-limits.md gives and its
siblings record — and on its merits, because it is the only part of seed construction that asks a
question about the TREE rather than about the row's shape.

WHY IT EXISTS. Measured on the first live verify run (2026-10-06): control (d) reported 4 of 4 seeds
missed, and 2 of those 4 were the SEEDS' fault. A closed seed is an archived entry's prose with its
resolution markers stripped, and some of those entries name only files the very commit that closed
them deleted. The verifier is then asked to show `STALE-FIXED` about code that is not there, answers
`NOT-VERIFIABLE` — which is CORRECT about the repo — and is scored a miss. The one control that
measures judgement was rewarding a guess over an honest abstention, and a re-dispatch triggered by such
a miss re-runs a chunk nothing was wrong with.

WHAT IT CANNOT DO, so nothing here reads stronger than it is. It decides whether the EVIDENCE is
reachable, never whether the prose still states a checkable claim — no predicate can. That residue is
covered the other way round: `zuvo_backlog_agent.check_seeds` grades `NOT-VERIFIABLE` on a closed seed
as an abstention rather than a miss.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, as in every sibling: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. This module does NOT
import the parser, so it is outside the H19c pin-guard family by construction: it holds no
`iter_entries` call and has no path to one.
"""
import os
from typing import Tuple

import zuvo_backlog_verdicts as zv


def closed_refusal(body: str, tree: zv.Tree) -> str:
    """The REASON a closed seed's expected `STALE-FIXED` is not derivable from `tree`, or "" when it is.

    A REASON STRING, and the name says so. Both predicates here were first called `*_derivable`, which
    reads as a boolean whose truthy value means "yes" while it actually means "no, and here is why" —
    four of the five reviewers of this change flagged the polarity. The caller is `if why: drop`, so
    the inversion was only inferable from a local variable name.

    `body` is the seed AS DISPATCHED — markers stripped, identity removed — because that is the text
    the verifier is asked about, and the question is what IT can conclude.

    THE RULE: if the entry names paths and NONE of them resolve, the production-path evidence shape is
    impossible and the honest answer about the tree is `NOT-VERIFIABLE` (or `STALE-OBSOLETE`), not the
    `STALE-FIXED` the answer key holds. An entry that names NO path stays admissible: its proving shape
    is the archive line, which `backlog-done.md` still holds — that is the second evidence shape the
    include's table permits for this verdict, and the one control (c) calls `archive-proof`.

    NOT a check that the seed keys into the archive. `zuvo_backlog_seedshape._unidentified`
    deliberately strips the source
    entry's id so the seed cannot be looked up and cannot collide with the real row, which changes the
    content key by construction — so "the archive still holds this key" is false for a correctly built
    seed and would drop every one of them.
    """
    # DELIBERATELY WEAKER THAN ITS SIBLING, and the asymmetry follows the evidence rather than
    # convenience: a closed seed's proving shape is the ARCHIVE line, which always resolves, so all
    # this has to rule out is the one case where the tree can show nothing at all. `live_refusal` can
    # ask more because a live seed's proof IS a line of the tree, so it checks the line.
    paths = zv.cited_paths(body)
    if not paths:
        return ""
    for path in paths:
        target = zv.resolve_cited(path, tree)
        if target and os.path.exists(target):
            return ""
    return ("names only paths that are gone at this commit (%s), so the tree cannot show the fix and "
            "NOT-VERIFIABLE is the honest answer" % ", ".join(paths[:3]))


def live_refusal(anchor: Tuple[str, int, str], tree: zv.Tree) -> str:
    """The REASON a live seed's expected `STILL-REAL` is not derivable from `tree`, or "" when it is.

    `live_anchors` reads these out of the tree, so at first sight the check is vacuous — and it is not,
    because the ROOT can differ. `cmd_dispatch` derives anchors from `loaded.root` while the verifier
    resolves citations through `resolve_cited` against `tree.root`, and `main_root` makes those two
    different directories for every linked worktree. An anchor the verifier cannot resolve is a seed
    whose expected verdict is underivable for exactly the reason this function exists to catch.
    """
    path, line, text = anchor
    target = zv.resolve_cited(path, tree)
    if not target or not os.path.exists(target):
        return "cites %s, which does not resolve against the dispatched tree" % path
    try:
        with open(target, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        return "cites %s, which cannot be read (%s)" % (path, exc)
    # `line < 1` is checked, not assumed: `_candidates` numbers from 1, but this predicate takes the
    # anchor from a CALLER, and `lines[-1]` would quietly answer about the last line of the file.
    if line < 1 or line > len(lines):
        return "cites %s:%d, which the file does not have" % (path, line)
    # THE QUOTE MUST BE NON-EMPTY BEFORE IT CAN BE FOUND. `"" in s` is True for every `s`, so an
    # anchor whose text is empty or whitespace-only would make any in-range line "derivable" —
    # vacuously, which in a control is the fail-OPEN direction. `_candidates` demands four words so
    # `live_anchors` cannot produce one, and this function takes its anchor from a CALLER, which is
    # the whole reason it exists. Caught by the cross-model review of this change.
    quote = " ".join(text.split()[:8])
    if not quote:
        return "cites %s:%d but quotes nothing, so no line can confirm it" % (path, line)
    if quote not in " ".join(lines[line - 1].split()):
        return "cites %s:%d, which no longer reads what the anchor quotes" % (path, line)
    return ""
