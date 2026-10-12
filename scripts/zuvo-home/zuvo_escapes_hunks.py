"""The diff a --classify prompt shows: the escaped lines' hunks first, cut to a size budget.

A length cut that keeps the top of a long diff can drop the very hunk the model is asked about. So for
each escaped file the hunks holding an escaped line come first (its header with them), then every other
hunk of every file; only that order is cut. Lines are found on the side the row names them: the
introducing commit's NEW side (intro_line), the fix's OLD side (line_at_parent, the line at the fix's
parent). The text is split at the newline character only, so a form feed inside a line never starts a
fake hunk header.
"""

from __future__ import annotations

import re

import zuvo_escapes_fixwalk as fw

CUT_MARK = "\n[diff cut]"
_HUNK = re.compile(r"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@")


def _holds(header: str, numbers: set[int], new_side: bool) -> bool:
    m = _HUNK.match(header)
    if not m:
        return False
    start, count = (m.group(3), m.group(4)) if new_side else (m.group(1), m.group(2))
    first, n = int(start), int(count) if count is not None else 1
    return any(first <= x < first + n for x in numbers)


def _split(diff: str) -> tuple[str, list[str]]:
    """(the file header, each hunk with its own lines) of a one-file diff."""
    header: list[str] = []
    hunks: list[list[str]] = []
    for line in diff.split("\n"):
        if line.startswith("@@"):
            hunks.append([line])
        elif hunks:
            hunks[-1].append(line)
        else:
            header.append(line)
    return "".join(x + "\n" for x in header), ["\n".join(h).rstrip("\n") + "\n" for h in hunks]


def ordered(repo: str, rev: str, wanted: dict[str, set[int]], new_side: bool,
            budget: int) -> tuple[str, bool]:
    """(the diff of `rev` against its first parent for the paths of `wanted`, hunks holding the wanted
    line numbers first, at most `budget` characters; whether it was cut). Raises fw.GitError."""
    first: list[str] = []
    rest: list[str] = []
    for path in sorted(wanted):
        out = fw.git(repo, "show", "--format=", "--no-color", "-U3", "--first-parent", "-m", rev, "--", path)
        header, hunks = _split(out)
        mine = [h for h in hunks if _holds(h, wanted[path], new_side)]
        other = [h for h in hunks if not _holds(h, wanted[path], new_side)]
        if mine or not other:
            first.append(header + "".join(mine))
        if other:
            rest.append(header + "".join(other))
    text = "".join(first) + "".join(rest)
    if len(text) <= budget:
        return text, False
    return text[:budget] + CUT_MARK, True
