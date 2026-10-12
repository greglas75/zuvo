"""Blame each production line a fix removes or rewrites to the commit that introduced it (SZZ).

Whitespace is ignored on both sides (diff -w, blame -w). What is not attributed is counted under
`skipped`, by reason; the unit differs per reason:

  per fix commit   in_fix_merge     a fix-named commit a fix merge brought in (the merge is the fix)
                   mass_files       touches >= --mass-files files: a rename or reformat, not a fix
                   whitespace_only  changes nothing but whitespace (not counted as a fix)
                   non_production   touches no production path (not counted as a fix)
                   git_error        its diff could not be read (shallow clone, timeout); the run goes on
                   root_fix         has no parent to diff against (first commit, shallow graft)
                   deadline         not started: the --deadline budget ran out (deadline_hit is true).
                                    The budget is checked between fixes; one fix is bounded by
                                    the git timeouts of its few calls, not by the deadline
  per file         non_production_path  test / lock / generated / docs path inside a fix
                   deleted_file     a production file the fix deletes (dead code, not a defect)
                   binary           a binary production file
                   blame_error      a file git could not blame
  per line         too_old          introduced before now - --max-age
                   no_landing       its introducing commit was not reached by the landing walk (a
                                    clock-skewed first-parent commit stops it)
                   shallow_boundary blamed to a shallow clone's graft commit, not to its real origin
                   same_merge       introduced and fixed inside one landing: fixed before review
                   blame_parse      blame gave no commit time for the line (unreadable output)

`escapes` counts rows (lines); `escape_pairs` counts distinct (fix, introducing commit) pairs, so one
large fix rewriting many lines of one bad commit weighs as one escape in a rate. A counted fix with
nothing to blame — it only ADDS lines, or every production file it touches is added, deleted or binary
— is `unattributed` and writes no row: the SZZ limit, reported rather than guessed. Fixes are scanned
newest landing first, so a deadline cut drops the oldest landings; the rows come back sorted by key.

Row schema (one per escaped line): key = fix_sha:file:line_at_parent; project; fix_sha, fix_subject,
fix_ts, fix_landing_sha, fix_landing_ts, fix_week (ISO week of the fix's landing); file and
line_at_parent — the path and line at the fix's PARENT, so a file the fix renames keeps its pre-rename
path; intro_sha, intro_file, intro_line (the line in the introducing commit), intro_ts,
intro_landing_sha, intro_landing_ts. Never an author address, never a line of the diff.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
import tempfile
import time
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, NamedTuple

import zuvo_escapes_fixwalk as fw
import zuvo_escapes_patch as pt
from zuvo_review_prodpath import is_production

SUBJECT_MAX = 200
IGNORE_REVS = ".git-blame-ignore-revs"
_HEADER = re.compile(r"^([0-9a-f]{40}) ([0-9]+) ([0-9]+)(?: [0-9]+)?$")


class BlameLine(NamedTuple):
    final_line: int  # line number at the blamed revision (the fix's parent)
    sha: str
    orig_line: int
    orig_file: str
    ts: int


@dataclass(frozen=True)
class Options:
    ref: str
    since: dt.timedelta
    max_age: dt.timedelta
    mass_files: int
    deadline_s: int = 900


@dataclass
class Summary:
    fixes: int = 0
    escapes: int = 0
    escape_pairs: int = 0
    unattributed: int = 0
    deadline_hit: bool = False
    skipped: Counter[str] = field(default_factory=Counter)

    def as_dict(self) -> dict[str, Any]:
        return {"fixes": self.fixes, "escapes": self.escapes, "escape_pairs": self.escape_pairs,
                "unattributed": self.unattributed, "deadline_hit": self.deadline_hit,
                "skipped": dict(sorted(self.skipped.items()))}


@dataclass
class _Scan:
    repo: str
    project: str
    opts: Options
    landings: dict[str, fw.Landing]
    ignore_revs: str | None
    shallow: frozenset[str]
    cutoff_ts: int  # the landing walk's horizon
    oldest_ts: int  # now - max_age
    summary: Summary = field(default_factory=Summary)
    records: list[dict[str, Any]] = field(default_factory=list)


def parse_porcelain(text: str) -> tuple[list[BlameLine], int]:
    """`git blame --porcelain` -> (one BlameLine per blamed line, lines dropped because their commit
    never got a committer-time). A commit's metadata (time, filename) is printed only the first time
    the commit appears, so it is remembered per sha."""
    out: list[BlameLine] = []
    bad = 0
    ts: dict[str, int] = {}
    files: dict[str, str] = {}
    cur: tuple[str, int, int] | None = None
    for line in text.splitlines():
        if line.startswith("\t"):
            if cur is not None:
                sha, orig, final = cur
                if sha in ts:
                    out.append(BlameLine(final, sha, orig, files.get(sha, ""), ts[sha]))
                else:
                    bad += 1
            cur = None
            continue
        m = _HEADER.match(line)
        if m:
            cur = (m.group(1), int(m.group(2)), int(m.group(3)))
        elif cur is not None and line.startswith("committer-time "):
            value = line.split(" ", 1)[1].strip()
            if value.isdigit():  # anything else leaves the commit without a time: blame_parse
                ts[cur[0]] = int(value)
        elif cur is not None and line.startswith("filename "):
            files[cur[0]] = pt.unquote(line.split(" ", 1)[1])
    return out, bad


def blame(repo: str, rev: str, path: str, ranges: tuple[tuple[int, int], ...],
          ignore_revs: str | None) -> tuple[list[BlameLine], int]:
    # An inherited blame.ignoreRevsFile naming a missing file makes git fail outright: clear it, and
    # pass the ref's own list explicitly when it has one.
    args = ["-c", "blame.ignoreRevsFile=", "blame", "-w", "--porcelain"]
    if ignore_revs:
        args += ["--ignore-revs-file", ignore_revs]
    for start, count in ranges:
        args += ["-L", f"{start},+{count}"]
    return parse_porcelain(fw.git(repo, *args, rev, "--", path))


def ignore_revs_at(repo: str, ref: str, tmpdir: str) -> str | None:
    """The ref's .git-blame-ignore-revs copied into `tmpdir` (the working tree may be on any branch);
    None when the ref has none."""
    try:
        fw.git(repo, "cat-file", "-e", f"{ref}:{IGNORE_REVS}")
    except fw.GitError:
        return None
    path = os.path.join(tmpdir, "ignore-revs")
    with open(path, "w", encoding="utf-8") as f:
        f.write(fw.git(repo, "cat-file", "blob", f"{ref}:{IGNORE_REVS}"))
    return path


def _iso(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _iso_week(ts: int) -> str:
    year, week, _ = dt.datetime.fromtimestamp(ts, dt.timezone.utc).isocalendar()
    return f"{year}-W{week:02d}"


def _record(s: _Scan, fix: fw.Commit, fix_landing: fw.Landing, path: str, bl: BlameLine,
            intro_landing: fw.Landing) -> dict[str, Any]:
    return {
        "key": f"{fix.sha}:{path}:{bl.final_line}",
        "project": s.project,
        "fix_sha": fix.sha, "fix_subject": fix.subject[:SUBJECT_MAX], "fix_ts": _iso(fix.ts),
        "fix_landing_sha": fix_landing.sha, "fix_landing_ts": _iso(fix_landing.ts),
        "fix_week": _iso_week(fix_landing.ts),
        "file": path, "line_at_parent": bl.final_line,
        "intro_sha": bl.sha, "intro_file": bl.orig_file or path, "intro_line": bl.orig_line,
        "intro_ts": _iso(bl.ts), "intro_landing_sha": intro_landing.sha,
        "intro_landing_ts": _iso(intro_landing.ts),
    }


def _attribute(s: _Scan, fix: fw.Commit, fix_landing: fw.Landing, path: str,
               lines: list[BlameLine]) -> None:
    for bl in lines:
        intro_landing = s.landings.get(bl.sha)
        if bl.sha in s.shallow:
            s.summary.skipped["shallow_boundary"] += 1
        elif intro_landing is None:
            # older than the walk's horizon, or behind something the walk stopped at
            s.summary.skipped["too_old" if bl.ts < s.cutoff_ts else "no_landing"] += 1
        elif intro_landing.ts < s.oldest_ts:
            s.summary.skipped["too_old"] += 1
        elif intro_landing.sha == fix_landing.sha:
            s.summary.skipped["same_merge"] += 1
        else:
            s.records.append(_record(s, fix, fix_landing, path, bl, intro_landing))
            s.summary.escapes += 1


def _production_patches(s: _Scan, fix: fw.Commit) -> list[pt.FilePatch] | None:
    """The fix's production file patches, or None when the fix is skipped as a whole (counted)."""
    parent = fix.parents[0]
    if pt.touched_count(s.repo, parent, fix.sha) >= s.opts.mass_files:
        s.summary.skipped["mass_files"] += 1
        return None
    patches = pt.file_patches(s.repo, parent, fix.sha)
    prod = [p for p in patches if is_production(p.path)]
    if len(prod) < len(patches):
        s.summary.skipped["non_production_path"] += len(patches) - len(prod)
    if not patches:
        s.summary.skipped["whitespace_only"] += 1
    elif not prod:
        s.summary.skipped["non_production"] += 1
    return prod or None


def _scan_fix(s: _Scan, fix: fw.Commit) -> None:
    prod = _production_patches(s, fix)
    if prod is None:
        return
    s.summary.fixes += 1
    fix_landing = s.landings.get(fix.sha, fw.Landing(fix.sha, fix.ts))
    blamed_any = False
    for patch in prod:
        if patch.deleted or patch.binary:
            s.summary.skipped["deleted_file" if patch.deleted else "binary"] += 1
            continue
        if patch.added or not patch.ranges:
            continue
        blamed_any = True
        try:
            lines, bad = blame(s.repo, fix.parents[0], patch.path, patch.ranges, s.ignore_revs)
        except fw.GitError as exc:
            s.summary.skipped["blame_error"] += 1
            sys.stderr.write(f"review-escapes: {fix.sha[:10]} {patch.path}: {exc}\n")
            continue
        if bad:
            s.summary.skipped["blame_parse"] += bad
        _attribute(s, fix, fix_landing, patch.path, lines)
    if not blamed_any:
        s.summary.unattributed += 1


def newest_landing_first(fixes: list[fw.Commit], landings: dict[str, fw.Landing]) -> list[fw.Commit]:
    """`fixes` ordered by landing time, newest first (own commit time when it has no landing)."""
    def landed(c: fw.Commit) -> int:
        landing = landings.get(c.sha)
        return landing.ts if landing else c.ts
    return sorted(fixes, key=lambda c: (-landed(c), c.sha))


def _scan_fixes(s: _Scan, fixes: list[fw.Commit], started: float) -> None:
    for i, fix in enumerate(fixes):
        if time.monotonic() - started >= s.opts.deadline_s:
            s.summary.deadline_hit = True
            s.summary.skipped["deadline"] += len(fixes) - i
            return
        try:
            _scan_fix(s, fix)
        except fw.GitError as exc:
            s.summary.skipped["git_error"] += 1
            sys.stderr.write(f"review-escapes: {fix.sha[:10]}: {exc}\n")


def scan(repo: str, project: str, opts: Options, now: dt.datetime) -> tuple[list[dict[str, Any]], Summary]:
    """Every escape row for fixes that landed in [now - since, now], newest first until the deadline,
    plus the run's summary. Raises fw.GitError when the ref cannot be walked; a fix whose diff cannot
    be read, or a file that cannot be blamed, is only counted."""
    started = time.monotonic()
    if now.tzinfo is None:  # a naive `now` is UTC, never the host's local time
        now = now.replace(tzinfo=dt.timezone.utc)
    since_ts = int((now - opts.since).timestamp())
    oldest_ts = int((now - opts.max_age).timestamp())
    cutoff_ts = min(since_ts, oldest_ts)
    with tempfile.TemporaryDirectory(prefix="review-escapes-") as tmp:
        s = _Scan(repo, project, opts, fw.landing_map(repo, opts.ref, cutoff_ts),
                  ignore_revs_at(repo, opts.ref, tmp), fw.shallow_commits(repo), cutoff_ts, oldest_ts)
        fixes, skipped = fw.walk_fixes(repo, opts.ref, since_ts)
        s.summary.skipped.update({k: n for k, n in skipped.items() if n})
        _scan_fixes(s, newest_landing_first(fixes, s.landings), started)
    s.summary.escape_pairs = len({(r["fix_sha"], r["intro_sha"]) for r in s.records})
    s.records.sort(key=lambda r: r["key"])
    return s.records, s.summary
