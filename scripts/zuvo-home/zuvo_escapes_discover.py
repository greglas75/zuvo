"""Which files are review artifacts, and where review-escapes looks for them.

An artifact is a memory/reviews/*.md file with the push gate's headers (hooks/lib/pipeline-gate-lib.sh,
same rules): the `<!-- zuvo-review -->` marker on any header line, the first `range: <base>..<head>`
and the first `files:` line, split on commas only and trimmed, `*` meaning every file. A file without
the marker (the dated, header-less reports) is not an artifact. `status: PROVISIONAL` (head WORKTREE)
reviewed uncommitted edits; its `blobs: path=<blob>` entries say what content was seen (a value that
is not a 40- or 64-hex object id is ignored: it would be read as a revision spec).

Sources, first copy of a file name wins: the main checkout, every linked worktree, the review archive
(~/.zuvo/review-archive/<project>/reviews, or $ZUVO_REVIEW_ARCHIVE), then the hosts' archive copies
under ~/.zuvo/remote/ — a checkout copy is the one a later correction was made to. A copy that cannot
be opened is passed over (the next copy of the name counts); a copy that opens but is not an artifact
(its marker removed) still claims the name, so un-marking a checkout copy withdraws the archived ones.
"""

from __future__ import annotations

import itertools
import os
import re
from collections.abc import Iterator
from typing import NamedTuple

import zuvo_escapes_fixwalk as fw
from zuvo_review_ledger import remote_roots, zuvo_home

MARKER = "<!-- zuvo-review -->"
HEADER_LINES = 400
WORKTREE = "WORKTREE"
_RANGE = re.compile(r"^(\S+)\.\.(\S+)$")
_OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


class Artifact(NamedTuple):
    name: str
    files: frozenset[str] | None  # None: `files: *`
    base: str
    head: str
    provisional: bool
    blobs: dict[str, str]


def parse_artifact(path: str) -> Artifact | None:
    """The artifact's headers, or None when the file is not an artifact the gate would read."""
    marker, found = False, {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in itertools.islice(f, HEADER_LINES):
            text = line.rstrip("\r\n")
            marker = marker or MARKER in text
            for key in ("files", "range", "status", "blobs"):
                if key not in found and text.startswith(key + ":"):
                    found[key] = text[len(key) + 1:].strip()
    m = _RANGE.match(found.get("range", ""))
    if not marker or "files" not in found or not found["files"] or not m:
        return None
    files = None if found["files"] == "*" else frozenset(
        e.strip() for e in found["files"].split(",") if e.strip())
    pairs = (e.split("=", 1) for e in found.get("blobs", "").split(",") if "=" in e)
    blobs = {k.strip(): v.strip().lower() for k, v in pairs if _OID.match(v.strip().lower())}
    provisional = found.get("status", "").upper() == "PROVISIONAL" or m.group(2) == WORKTREE
    return Artifact(os.path.basename(path), files, m.group(1), m.group(2), provisional, blobs)


def review_dirs(repo: str, project: str) -> Iterator[str]:
    out = fw.git(repo, "worktree", "list", "--porcelain")
    for line in out.splitlines():
        if line.startswith("worktree "):
            yield os.path.join(line[9:], "memory", "reviews")
    archive = os.environ.get("ZUVO_REVIEW_ARCHIVE") or os.path.join(zuvo_home(), "review-archive")
    yield os.path.join(archive, project, "reviews")
    yield from remote_roots(os.path.join("review-archive", project, "reviews"))


def discover(repo: str, project: str) -> list[Artifact]:
    seen: set[str] = set()
    found: list[Artifact] = []
    for d in review_dirs(repo, project):
        try:
            with os.scandir(d) as entries:
                names = sorted(e.name for e in entries if e.name.endswith(".md") and e.is_file())
        except OSError:
            continue  # a worktree without memory/reviews, or one removed since `worktree list`
        for name in names:
            if name in seen:
                continue
            try:
                art = parse_artifact(os.path.join(d, name))
            except OSError:
                continue  # unreadable here: a later copy of the name may still be read
            seen.add(name)  # even when not an artifact: an un-marked copy withdraws the later ones
            if art is not None:
                found.append(art)
    return found
