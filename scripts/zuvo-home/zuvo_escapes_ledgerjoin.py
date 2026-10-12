"""Did a review flag the line an escape blames, and what became of that flag? Read from the ledgers.

A finding (a non-verdict row of the adversarial findings ledger — this host's and every host copy
under ~/.zuvo/remote/) flags an escape row when all hold:
- project: the same basename (`/Users/…/repo`, `/home/…/repo/` and `repo` are one project);
- path: one path ends with the other on whole path segments, compared against the row's path at the
  fix's parent and at the introducing commit. The row's path is whole (repo-relative), so a finding path
  LONGER than it joins only when absolute (`/…`, `~/…`, `X:\\…`) and the segment right before the row's
  path is the project name (the checkout's basename — on any host: `/home/x/DEV/repo/…` and
  `/Users/y/DEV/repo/…` alike); a longer relative one, or one under another directory, names another
  file. A bare file name (one segment) joins only when exactly one file the fix touched has that name,
  and is reported as match=basename;
- line: within --line-window of the line it pairs with — the introducing commit's line for its path,
  the fix parent's line for that path (a finding made at review time sits where the line was then);
  a finding with no line number joins nothing;
- time: from 72 h before the introducing commit was authored up to (not including) the time the fix
  work started — the fix's own review flags the fix, not the escape. That start is the earliest author
  time among the fix's own commits (`fix ^fix^1`) that is not before the introducing commit (a long-lived
  fix branch can hold older, unrelated commits); with none, the fix commit's own author time. A row
  whose window git cannot read is left unflagged and counted (Join.unknown), never a crash.
Times are read by zuvo_escapes_gitbatch.parse_utc (fractional seconds and `+00:00` included); a finding
with an unreadable time joins nothing.

What became of it: the latest ledger verdict (fixed / deferred → accepted, rejected → dismissed) — the
disposition the review process itself made. With none, Bill's latest verdict on the finding id from
bill-data/defects.jsonl, this host's and the remote copies (real → accepted, false_positive →
dismissed; latest by parse_utc time, a record with an unreadable time skipped). Otherwise unjudged.
Only these verdicts compete for "latest": a newer verdict outside them (Bill's `uncertain`, a ledger
disposition this join has no mapping for) neither counts nor hides an older one. Over several matching
findings, accepted > dismissed > unjudged; the evidence lists at most EVIDENCE_MAX of them, those that
decided the state first (path matches before basename ones).
"""

from __future__ import annotations

import os
import re
from collections.abc import Iterable
from typing import Any, NamedTuple

import zuvo_escapes_fixwalk as fw
from zuvo_escapes_gitbatch import cat_file, commit_ts, parse_utc
from zuvo_review_ledger import (iter_jsonl, latest_verdicts, ledger_path, project_key, read_rows,
                                remote_roots, split_file, zuvo_home)

LEAD_S = 72 * 3600
EVIDENCE_MAX = 5
STRENGTH = {"none": 0, "unjudged": 1, "dismissed": 2, "accepted": 3}
_LEDGER = {"fixed": "accepted", "deferred": "accepted", "rejected": "dismissed"}
_BILL = {"real": "accepted", "false_positive": "dismissed"}
_ABSOLUTE = re.compile(r"^(?:/|~/|[A-Za-z]:[\\/])")


class Finding(NamedTuple):
    fingerprint: str
    segments: tuple[str, ...]
    line: int
    ts: int
    absolute: bool


class Flag(NamedTuple):
    flagged: str  # accepted | dismissed | unjudged | none
    findings: list[str]
    match: str | None  # path | basename


def _segments(path: str) -> tuple[str, ...]:
    return tuple(s for s in path.replace("\\", "/").split("/") if s and s != ".")


def ledger_files() -> list[str]:
    return [ledger_path(), *remote_roots("adversarial-findings.log")]


def load(project: str) -> tuple[list[Finding], dict[str, str]]:
    """(this project's line-level findings, fingerprint -> flagged state of its latest verdict)."""
    rows = [r for path in ledger_files() for r in read_rows(path) if r.project_key == project]
    seen: set[tuple[str, str, str]] = set()
    findings: list[Finding] = []
    for r in rows:
        path, line = split_file(r.file)
        ts = parse_utc(r.ts)
        key = (r.fingerprint, r.file, r.ts)
        if r.is_verdict or path is None or line is None or ts is None or key in seen:
            continue
        seen.add(key)
        absolute = bool(_ABSOLUTE.match(path.strip()))
        findings.append(Finding(r.fingerprint, _segments(path), line, ts, absolute))
    states = {fp: _BILL.get(v, "unjudged") for fp, v in _bill_verdicts(project).items()}
    known = latest_verdicts(r for r in rows if r.disposition in _LEDGER)
    states.update({fp: _LEDGER[d] for (_, fp), d in known.items()})
    return findings, states


def _bill_verdicts(project: str) -> dict[str, str]:
    local = os.path.join(zuvo_home(), "bill-data", "defects.jsonl")
    files = [local, *remote_roots("bill-data/defects.jsonl")]
    best: dict[str, tuple[int, str]] = {}
    for rec in (r for f in files for r in iter_jsonl(f)):
        ids, ts, v = rec.get("finding_ids"), parse_utc(rec.get("ts")), rec.get("verdict")
        proj = rec.get("project")
        if not (isinstance(ids, list) and ts is not None and isinstance(v, str) and v in _BILL
                and isinstance(proj, str) and project_key(proj) == project):
            continue
        for fid in (i for i in ids if isinstance(i, str)):
            if fid not in best or ts >= best[fid][0]:
                best[fid] = (ts, v)
    return {fid: v for fid, (_, v) in best.items()}


class Join:
    """Findings of one project joined to escape rows; per-commit git reads are made once."""

    def __init__(self, repo: str, project: str, window: int) -> None:
        self.repo, self.project, self.window = repo, project, window
        self.findings, self.states = load(project)
        self._by_name: dict[str, list[Finding]] = {}  # last path segment -> findings: flag() reads only these
        for f in self.findings:
            if f.segments:
                self._by_name.setdefault(f.segments[-1], []).append(f)
        self._names: dict[str, list[str]] = {}
        self._authored: dict[str, int] = {}
        self._fix_times: dict[str, list[int]] = {}
        self.unknown = 0  # rows whose time window git could not read: left unflagged

    def prefetch(self, rows: list[dict[str, Any]]) -> None:
        """Every introducing commit's author time in one git process (else read one by one on use)."""
        try:
            raw = cat_file(self.repo, sorted({r["intro_sha"] for r in rows}))
        except fw.GitError:
            return
        for sha, obj in raw.items():
            try:
                self._authored[sha] = _epoch_digits(commit_ts(obj, "author") or "")
            except ValueError:
                continue  # read again, one by one, on use

    def _fix_names(self, fix: str) -> list[str]:
        """Base names of the files the fix touched; none (no basename join) when git cannot list them."""
        if fix not in self._names:
            try:
                out = fw.git(self.repo, "diff", "--name-only", "-z", "--no-renames", f"{fix}^1", fix)
            except fw.GitError:
                out = ""
            self._names[fix] = [os.path.basename(p) for p in out.split("\0") if p]
        return self._names[fix]

    def _window(self, row: dict[str, Any]) -> tuple[int, int] | None:
        """[introducing commit's author time - 72 h, start of the fix work) — see the module docstring;
        None when git cannot read either end."""
        intro, fix = row["intro_sha"], row["fix_sha"]
        try:
            if intro not in self._authored:
                self._authored[intro] = _epoch_digits(fw.git(self.repo, "show", "-s", "--format=%at", intro))
            if fix not in self._fix_times:
                own = fw.git(self.repo, "show", "-s", "--format=%at", fix)
                side = fw.git(self.repo, "log", "--format=%at", fix, f"^{fix}^1")
                self._fix_times[fix] = [_epoch_digits(own), *(_epoch_digits(t) for t in side.split())]
        except (fw.GitError, ValueError):
            return None
        authored, (own_ts, *side_ts) = self._authored[intro], self._fix_times[fix]
        end = min((t for t in side_ts if t >= authored), default=own_ts)
        return authored - LEAD_S, end

    def _path_match(self, f: Finding, path: str, fix: str) -> str | None:
        mine, theirs = _segments(path), f.segments
        if len(theirs) > len(mine):
            root = len(theirs) - len(mine)
            ok = f.absolute and bool(mine) and theirs[root:] == mine and theirs[root - 1] == self.project
            return "path" if ok else None
        if not theirs or mine[len(mine) - len(theirs):] != theirs:
            return None
        if len(theirs) > 1:
            return "path"
        return "basename" if self._fix_names(fix).count(theirs[0]) == 1 else None

    def flag(self, row: dict[str, Any]) -> Flag:
        window = self._window(row)
        if window is None:
            self.unknown += 1
            return Flag("none", [], None)
        start, end = window
        pairs = [(row["intro_file"], row["intro_line"]), (row["file"], row["line_at_parent"])]
        hits: dict[str, str] = {}
        names = {seg[-1] for seg in (_segments(p) for p, _ in pairs) if seg}
        for f in (f for name in sorted(names) for f in self._by_name.get(name, ())):
            if not start <= f.ts < end:
                continue
            for path, line in pairs:
                near = abs(f.line - line) <= self.window
                kind = self._path_match(f, path, row["fix_sha"]) if near else None
                if kind and hits.get(f.fingerprint) != "path":
                    hits[f.fingerprint] = kind
        return self._resolve(hits)

    def _resolve(self, hits: dict[str, str]) -> Flag:
        if not hits:
            return Flag("none", [], None)
        state = max((self.states.get(fp, "unjudged") for fp in hits), key=STRENGTH.__getitem__)
        match = "path" if "path" in hits.values() else "basename"
        decisive = sorted(hits, key=lambda fp: (self.states.get(fp, "unjudged") != state,
                                                 hits[fp] != "path", fp))
        return Flag(state, decisive[:EVIDENCE_MAX], match)


def _epoch_digits(text: str) -> int:
    """A git `%at` value; ValueError when it is not one (empty output, a root commit's missing side)."""
    text = text.strip()
    if not (text.isascii() and text.isdigit()):
        raise ValueError(f"not an epoch: {text!r}")
    return int(text)


def strongest(states: Iterable[str]) -> str:
    return max(states, key=STRENGTH.__getitem__, default="none")
