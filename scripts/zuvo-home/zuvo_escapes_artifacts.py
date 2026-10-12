"""Was the line an escape blames ever in front of a code review? Read from the review artifacts
(which files are artifacts, and where they are found: zuvo_escapes_discover).

An escape row is reviewed by an artifact listing its path when either
- ancestry: the introducing commit is in base..head (an ancestor of head, not of base; the range's
  commit list is read once per artifact) and none of the fix's own commits (`fix ^fix^1`: the fix,
  and for a merge every commit its side brought in) is head or an ancestor of head — a range holding
  any of them shows a diff in which the bug is already gone. When git cannot say, nothing is granted;
- content, when ancestry cannot tell because the range never reached the ref (a squash or rebase gave
  the reviewed commits new shas): base resolves, head was committed no later than the introducing
  commit landed, the range changed the file at the introducing commit's path, and the introduced
  line's text is in head's copy of that path and not in base's (a base without the file: the range
  added it). Both conditions keep out a later review that moved or copied the file, to which every
  carried-along line looks new. A provisional artifact uses its recorded blob of that path as head
  and must sit below the line: its base is a proper ancestor of the introducing commit.
An unreadable time grants nothing it is needed for: an unknown intro_ts only skips the clock-skew
prefilter of the ancestry check, an unknown intro_landing_ts rules out content. Line numbers count
newline characters only, as blame does (str.splitlines() also breaks at form feeds and other
separators).
A committed artifact whose head or base object is gone (or whose fix ancestry git cannot read) grants
nothing and marks the row `range_unresolved`; a provisional one with an unresolvable base just grants
nothing. `reviewed/<hash>` tags only appear in the evidence.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from typing import Any, NamedTuple, TypeVar, cast

import zuvo_escapes_fixwalk as fw
from zuvo_escapes_discover import WORKTREE, Artifact
from zuvo_escapes_gitbatch import cat_file, commit_ts, parse_utc

SKEW_S = 86400  # committer clocks disagree; an ancestor is trusted to be at most this much "newer"
_SPACE = re.compile(r"\s+")
T = TypeVar("T")


class Verdict(NamedTuple):
    reviewed: bool
    artifact: str | None
    method: str | None
    provisional: bool
    range_unresolved: bool


def _norm(line: str) -> str:
    return _SPACE.sub("", line)  # blame -w ignores whitespace, so the comparison does too


def _split(text: str) -> list[str]:
    """The lines of a blob as blame numbers them: split at the newline character only (a trailing
    carriage return is whitespace to _norm); a final newline does not start another line."""
    parts = text.split("\n")
    return parts[:-1] if parts and parts[-1] == "" else parts


def _line(text: str, n: int) -> str | None:
    parts = _split(text)
    return _norm(parts[n - 1]) if 0 < n <= len(parts) else None


class Reviews:
    """The artifacts of one project and the git reads they need, each made once per run; prefetch()
    batches the per-artifact and per-row reads into a few git processes."""

    def __init__(self, repo: str, ref_sha: str, artifacts: list[Artifact]) -> None:
        self.repo, self.ref_sha = repo, ref_sha
        self.by_path: dict[str, list[Artifact]] = {}
        self.star = [a for a in artifacts if a.files is None]
        for a in artifacts:
            for p in a.files or ():
                self.by_path.setdefault(p, []).append(a)
        self._cache: dict[tuple[object, ...], Any] = {}
        self.tags = self._review_tags()
        self._reach: frozenset[str] | None = None

    def prefetch(self, rows: list[dict]) -> None:
        """Resolve every candidate range, read each head's commit time and each row's introduced line,
        in three git processes. Whatever fails here is read again, one object at a time, on use."""
        arts = {a.name: a for row in rows for a in self.candidates(row)}.values()
        revs = [rev for a in arts for rev in (a.base, a.head) if rev != WORKTREE]
        try:
            resolved = cat_file(self.repo, [f"{rev}^{{commit}}" for rev in revs], check=True)
            for rev in revs:
                oid = resolved.get(f"{rev}^{{commit}}")
                self._cache[("c", rev)] = oid.decode("ascii") if oid else None
            heads = [h for h in (self._cache.get(("c", a.head)) for a in arts) if h]
            for head, raw in cat_file(self.repo, heads).items():
                self._cache[("t", head)] = commit_ts(raw, "committer")
            wanted: dict[str, tuple[str, str, set[int]]] = {}
            for row in rows:
                spec = f"{row['intro_sha']}:{row['intro_file']}"
                entry = wanted.setdefault(spec, (row["intro_sha"], row["intro_file"], set()))
                entry[2].add(row["intro_line"])
            for spec, raw in cat_file(self.repo, list(wanted)).items():
                sha, path, numbers = wanted[spec]
                text = None if raw is None else raw.decode("utf-8", "surrogateescape")
                for n in numbers:  # only the lines rows need, not the whole file per row
                    self._cache[("l", sha, path, n)] = None if text is None else _line(text, n)
        except fw.GitError:
            pass  # each read falls back to its own git call

    def _reachable(self, sha: str) -> bool:
        if self._reach is None:
            self._reach = frozenset(fw.git(self.repo, "rev-list", self.ref_sha).split())
        return sha in self._reach

    def _memo(self, key: tuple[object, ...], fn: Callable[[], T]) -> T | None:
        """fn() once per key; None when git cannot answer (a missing object is evidence, not a crash)."""
        if key not in self._cache:
            try:
                self._cache[key] = fn()
            except fw.GitError:
                self._cache[key] = None
        return cast("T | None", self._cache[key])

    def _commit(self, rev: str) -> str | None:
        return self._memo(("c", rev), lambda: fw.git(
            self.repo, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}").strip())

    def _range(self, base: str, head: str) -> frozenset[str] | None:
        return self._memo(("r", base, head), lambda: frozenset(
            fw.git(self.repo, "rev-list", head, f"^{base}").split()))

    def _ancestor(self, older: str, newer: str) -> bool | None:
        """older is newer or an ancestor of it; None when git cannot say."""
        out = self._memo(("a", older, newer), lambda: fw.git(self.repo, "merge-base", older, newer).strip())
        return None if out is None else out == older

    def _fix_reached(self, fix: str, head: str) -> bool | None:
        """Whether one of the fix's own commits (`fix ^fix^1`) is head or an ancestor of it; None when
        git cannot say (a root or missing fix, a timeout). The fix's side is listed once per fix."""
        side = self._memo(("s", fix), lambda: fw.git(self.repo, "rev-list", fix, f"^{fix}^1").split())
        if not side:
            return None
        outside = self._memo(("o", fix, head), lambda: fw.git(
            self.repo, "rev-list", fix, f"^{fix}^1", f"^{head}").split())
        return None if outside is None else len(outside) < len(side)

    def _absent(self, rev: str, path: str) -> bool:
        """rev's tree has no `path` — False when it has, or when git cannot say."""
        return self._memo(("p", rev, path), lambda: fw.git(
            self.repo, "ls-tree", "--name-only", rev, "--", path)) == ""

    def _changed(self, base: str, head: str) -> frozenset[str]:
        names = self._memo(("d", base, head), lambda: fw.git(
            self.repo, "diff", "--name-only", "-z", "--no-renames", base, head))
        return frozenset((names or "").split("\0"))

    def _ts(self, sha: str) -> int | None:
        out = self._memo(("t", sha), lambda: fw.git(self.repo, "show", "-s", "--format=%ct", sha).strip())
        return int(out) if out and out.isascii() and out.isdigit() else None

    def lines(self, spec: str) -> frozenset[str] | None:
        """The whitespace-free lines of the blob `spec` (`rev:path` or a blob sha); None if absent."""
        return self._memo(("b", spec), lambda: frozenset(
            _norm(x) for x in _split(fw.git(self.repo, "cat-file", "-p", spec))))

    def line_text(self, row: dict) -> str | None:
        """The whitespace-free text of the introduced line; None when unreadable or out of range."""
        sha, path, n = row["intro_sha"], row["intro_file"], row["intro_line"]
        return self._memo(("l", sha, path, n), lambda: _line(
            fw.git(self.repo, "cat-file", "-p", f"{sha}:{path}"), n))

    def _review_tags(self) -> dict[str, list[str]]:
        tags: dict[str, list[str]] = {}
        try:
            out = fw.git(self.repo, "for-each-ref", "refs/tags/reviewed/",
                         "--format=%(objectname) %(*objectname) %(refname:short)")
        except fw.GitError:
            return tags
        for parts in (line.split() for line in out.splitlines()):
            if len(parts) >= 2:
                tags.setdefault(parts[-2], []).append(parts[-1])
        return tags

    def review_tags(self, row: dict) -> list[str]:
        return sorted({t for sha in (row["intro_sha"], row.get("intro_landing_sha", ""))
                       for t in self.tags.get(sha, [])})

    def candidates(self, row: dict) -> list[Artifact]:
        listed = {a.name: a for p in {row["file"], row["intro_file"]} for a in self.by_path.get(p, [])}
        listed.update((a.name, a) for a in self.star)
        return [listed[k] for k in sorted(listed)]

    def verdict(self, row: dict) -> Verdict:
        provisional = unresolved = False
        for art in self.candidates(row):
            how, missing = self._check(art, row)
            if how:
                return Verdict(True, art.name, how, art.provisional, False)
            provisional = provisional or art.provisional
            unresolved = unresolved or (missing and not art.provisional)
        return Verdict(False, None, None, provisional, unresolved)

    def _check(self, art: Artifact, row: dict) -> tuple[str | None, bool]:
        """(how the artifact reviewed the line or None, whether a range object or the fix's ancestry
        could not be read)."""
        base = self._commit(art.base)
        if art.provisional:
            return ("content" if base and self._provisional(art, row, base) else None), False
        head = self._commit(art.head)
        if not head:
            return None, True
        head_ts, intro_ts = self._ts(head), parse_utc(row.get("intro_ts"))
        if base and (head_ts is None or intro_ts is None or head_ts + SKEW_S >= intro_ts):
            commits = self._range(base, head)
            if commits is not None and row["intro_sha"] in commits:
                reached = self._fix_reached(row["fix_sha"], head)
                return ("ancestry" if reached is False else None), reached is None
        if not base:
            return None, True
        landed = parse_utc(row.get("intro_landing_ts"))
        if landed is None or head_ts is None or head_ts > landed or self._reachable(head):
            return None, False
        return ("content" if self._content(row, base, f"{head}:{row['intro_file']}", head) else None), False

    def _provisional(self, art: Artifact, row: dict, base: str) -> bool:
        """Uncommitted edits on `base` showed the line: base is a proper ancestor of the introducing
        commit, the recorded blob has the line and base's copy of the path does not."""
        blob = art.blobs.get(row["intro_file"])
        if not blob or base == row["intro_sha"] or self._ancestor(base, row["intro_sha"]) is not True:
            return False
        return self._content(row, base, blob, None)

    def _content(self, row: dict, base: str, seen_spec: str, head: str | None) -> bool:
        line = self.line_text(row)
        if not line:
            return False
        path = row["intro_file"]
        if head and path not in self._changed(base, head):
            return False
        seen = self.lines(seen_spec)
        if seen is None or line not in seen:
            return False
        before = self.lines(f"{base}:{path}")
        return line not in before if before is not None else self._absent(base, path)
