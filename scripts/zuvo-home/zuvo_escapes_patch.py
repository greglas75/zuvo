"""Which lines a fix removes: its `git diff -U0 -w` parsed into removed-line ranges per file.

Whitespace is ignored as blame -w ignores it: a re-indented line is not a removed line, and a file
whose only change is whitespace does not appear at all. Paths come back as git prints them, with
its C-style quoting undone.
"""

from __future__ import annotations

import re
from typing import NamedTuple

import zuvo_escapes_fixwalk as fw

_HUNK = re.compile(r"^@@ -([0-9]+)(?:,([0-9]+))? \+[0-9]+(?:,([0-9]+))? @@")
_OCTAL = re.compile(r"[0-7]{3}")
_ESCAPES = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


class FilePatch(NamedTuple):
    path: str  # at the parent; the new path for an added file
    added: bool
    deleted: bool
    binary: bool
    ranges: tuple[tuple[int, int], ...]  # (first line at the parent, count) of each removing hunk


def touched_count(repo: str, parent: str, sha: str) -> int:
    out = fw.git(repo, "diff", "--name-only", "-z", "-M", "--no-ext-diff", parent, sha)
    return sum(1 for p in out.split("\0") if p)


def file_patches(repo: str, parent: str, sha: str) -> list[FilePatch]:
    """The fix's diff as removed-line ranges per file, one git call."""
    return parse_patch(fw.git(repo, "diff", "-U0", "-w", "--no-color", "--no-ext-diff", "-M",
                              "--src-prefix=a/", "--dst-prefix=b/", parent, sha))


def parse_patch(text: str) -> list[FilePatch]:
    """`git diff -U0` -> FilePatch per file. Hunk bodies (removed AND added lines) are skipped by the
    counts in their headers, so a body line that reads like a header (`--- x`, `@@ ..`) is never one."""
    out: list[FilePatch] = []
    cur: dict | None = None
    pending = 0
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            pending = 0  # a body cut short never runs into the next file's headers
            if cur is not None:
                out.append(_file_patch(cur))
            cur = {"old": _symmetric_path(line[11:]), "new": None, "added": False, "deleted": False,
                   "binary": False, "ranges": []}
        elif pending and line[:1] in ("-", "+", " "):
            pending -= 1
        elif cur is None or line.startswith("\\"):
            continue
        elif line.startswith(("--- ", "+++ ")):
            cur["old" if line[0] == "-" else "new"] = _path(line[4:])
        elif line.startswith("rename from "):
            cur["old"] = unquote(line[len("rename from "):])
        elif line.startswith("rename to "):
            cur["new"] = unquote(line[len("rename to "):])
        elif line.startswith(("new file mode", "deleted file mode", "Binary files ")):
            cur["added" if line[0] == "n" else "deleted" if line[0] == "d" else "binary"] = True
        elif m := _HUNK.match(line):
            old_n = 1 if m.group(2) is None else int(m.group(2))
            pending = old_n + (1 if m.group(3) is None else int(m.group(3)))
            if old_n:
                cur["ranges"].append((int(m.group(1)), old_n))
    if cur is not None:
        out.append(_file_patch(cur))
    return [p for p in out if p.path]


def _file_patch(cur: dict) -> FilePatch:
    path = cur["new"] if cur["added"] else cur["old"] or cur["new"]
    return FilePatch(path or "", cur["added"], cur["deleted"], cur["binary"], tuple(cur["ranges"]))


def _symmetric_path(rest: str) -> str | None:
    """The path of `a/P b/P` (an unquoted header whose two sides agree), else None."""
    n = (len(rest) - 5) // 2
    path = rest[2:2 + n]
    return path if n > 0 and rest == f"a/{path} b/{path}" else None


def _path(raw: str) -> str | None:
    # git appends a tab to a ---/+++ name that holds a space
    raw = raw[:-1] if raw.endswith("\t") else raw
    if raw == "/dev/null":
        return None
    raw = unquote(raw)
    return raw[2:] if raw[:2] in ("a/", "b/") else raw


def unquote(raw: str) -> str:
    """Git's C-style quoting (`"a/sp\\"ace\\303\\251"`) undone; an unquoted name is returned as is. A
    backslash that starts no valid escape (`\\9`, non-ASCII digits) is kept literally. Bytes that are
    not UTF-8 come back as surrogate escapes, so os.fsencode (and git's argv) get the original name — also
    one that arrives already surrogate-escaped (a raw byte inside a name git quoted for another reason)."""
    if len(raw) < 2 or raw[0] != '"' or raw[-1] != '"':
        return raw
    body, out, i = raw[1:-1], bytearray(), 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and _OCTAL.fullmatch(body[i + 1:i + 4]):
            out.append(int(body[i + 1:i + 4], 8) & 0xFF)
            i += 4
        elif ch == "\\" and body[i + 1:i + 2] in _ESCAPES:
            out.append(_ESCAPES[body[i + 1]])
            i += 2
        else:
            out += ch.encode("utf-8", "surrogateescape")
            i += 1
    return out.decode("utf-8", errors="surrogateescape")
