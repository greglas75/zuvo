"""HOW `backlog-add` ASKS WHETHER AN ENTRY IS ALREADY KNOWN: a fail-closed wrapper over
`backlog-archive.py lookup`, which answers over BOTH backlog files.

LOOKUP FAILS CLOSED. Only exit 10/11/0/13 with a single verdict line of the matching keyword is an answer;
anything else raises LookupFailed. Reading a failure as ABSENT writes a duplicate on every hiccup. The
archiver's stderr tail travels in the message, so the traceback of a crashed lookup is not lost with it.

The verdict grammar below mirrors `cmd_lookup`'s print statements; test_backlog_lookup.py runs the REAL
archiver against it, so a wording change on either side fails there rather than as LookupFailed in use.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from typing import NamedTuple, Optional

ARCHIVER_NAME = "backlog-archive.py"
LOOKUP_TIMEOUT_S = 30.0
STDERR_TAIL = 200
LOOKUP_OPEN, LOOKUP_ARCHIVED, LOOKUP_ABSENT = "open", "archived", "absent"
# The archiver refuses a candidate whose signature is empty (exit 13). That is an ANSWER, not a
# hiccup — a text with no words keys on nothing, so no entry can match it — and the caller falls
# through to filing a new entry exactly as it does for ABSENT. Leaving 13 out of the table made
# `_parse_verdict` raise LookupFailed on it, which is fail-closed in the wrong direction: the
# archiver gave a definite verdict and `backlog-add` would have died with "lookup failure".
LOOKUP_NO_SIGNATURE = "no-signature"

_KEY = r"(?P<key>(?:id|fp):\S+)"
_VERDICT_RES = {
    10: re.compile(r"OPEN " + _KEY + r" (?P<ident>\S+) backlog\.md:(?P<line>\d+)"
                   r"(?: \(ALSO ARCHIVED backlog-done\.md:(?P<also>\d+) — run verify\))?"),
    11: re.compile(r"ARCHIVED " + _KEY + r" (?P<ident>\S+) backlog-done\.md:(?P<line>\d+)"
                   r' section="(?P<section>.*)"'),
    0: re.compile(r"ABSENT " + _KEY),
    # No key group: the refusal happens BEFORE a key is computed, which is the whole point of it.
    13: re.compile(r"NO-SIGNATURE .+"),
}
_VERDICT_STATUS = {10: LOOKUP_OPEN, 11: LOOKUP_ARCHIVED, 0: LOOKUP_ABSENT,
                   13: LOOKUP_NO_SIGNATURE}


class LookupFailed(RuntimeError):
    """`backlog-archive.py lookup` gave no trustworthy answer. Never to be read as ABSENT."""


class Verdict(NamedTuple):
    status: str                    # LOOKUP_OPEN | LOOKUP_ARCHIVED | LOOKUP_ABSENT
    key: str                       # `id:<slug>` or `fp:<hex>`, as the archiver keyed the query
    ident: Optional[str]           # the matched entry's B-id; None for ABSENT or an id-less entry
    lineno: Optional[int]          # its line in backlog.md (OPEN) or backlog-done.md (ARCHIVED)
    section: Optional[str]         # ARCHIVED only: the archive section heading
    also_archived: Optional[int]   # OPEN only: the archive line when the key is in BOTH files


def archiver_path(here: Optional[str] = None, home: Optional[str] = None) -> Optional[str]:
    """`backlog-archive.py` beside this module (repo checkout or the flat ~/.zuvo install), else in
    `<home>/.zuvo`; None when neither exists. Both arguments exist for tests."""
    base = here if here is not None else os.path.dirname(os.path.realpath(__file__))
    root = home if home is not None else os.path.expanduser("~")
    for cand in (os.path.join(base, ARCHIVER_NAME), os.path.join(root, ".zuvo", ARCHIVER_NAME)):
        if os.path.isfile(cand):
            return cand
    return None


def _parse_verdict(rc: int, stdout: str, stderr: str) -> Verdict:
    rx = _VERDICT_RES.get(rc)
    lines = stdout.splitlines()
    m = rx.fullmatch(lines[0]) if rx is not None and len(lines) == 1 else None
    if m is None:
        # The TAIL of stderr: a traceback's last line names the exception, its head only the frames.
        raise LookupFailed(f"lookup gave rc={rc} and an unparseable answer: {stdout[:200]!r}"
                           f" stderr: {stderr[-STDERR_TAIL:]!r}")
    groups = m.groupdict()
    ident = groups.get("ident")
    line_no, also = groups.get("line"), groups.get("also")
    # `.get`, not `m["key"]`: the NO-SIGNATURE grammar has no key group, and indexing a group that the
    # pattern does not define raises IndexError — a crash where the point was to stop crashing.
    return Verdict(_VERDICT_STATUS[rc], groups.get("key") or "",
                   None if ident in (None, "-") else ident,
                   int(line_no) if line_no else None, groups.get("section"),
                   int(also) if also else None)


def lookup(repo: str, query: str, archiver: Optional[str] = None,
           timeout: float = LOOKUP_TIMEOUT_S) -> Verdict:
    """Ask `backlog-archive.py lookup` about a B-id or entry text, over BOTH backlog files. Raises
    LookupFailed on a missing archiver, a timeout, an exit outside {0,10,11,13} or an unparseable answer."""
    path = archiver if archiver is not None else archiver_path()
    if path is None or not os.path.isfile(path):
        raise LookupFailed(f"{ARCHIVER_NAME} not found (install incomplete): {path}")
    argv = [sys.executable, path, "lookup", "--repo", repo, "--", query]
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
                           check=False)
    except subprocess.TimeoutExpired as exc:
        raise LookupFailed(f"lookup timed out after {timeout}s") from exc
    except OSError as exc:
        raise LookupFailed(f"lookup could not start: {exc}") from exc
    return _parse_verdict(r.returncode, r.stdout.decode("utf-8", errors="replace"),
                          r.stderr.decode("utf-8", errors="replace"))
