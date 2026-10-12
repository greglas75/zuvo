"""Which checkout a review's verdicts are recorded from, decided BEFORE Bill pays to judge it.

The driver's `--record-disposition` keys a verdict by the absolute path of the git checkout it runs in and
accepts ids raised under that path or, when no other checkout shares it, under its bare basename. So a
review's `project` resolves to:

- an absolute path: itself, when it is a git checkout here;
- a bare name: ~/DEV/<name> when that is a git checkout, else an absolute path of that basename seen in
  a mirrored ledger (~/.zuvo/remote/**) that is a git checkout here.

A review that does not resolve is not judged this tick and costs nothing: it is re-checked on every tick
(a volume comes back, a repo gets cloned) until it leaves the age window. set_aside() logs it once in
bill-data/unrecordable.jsonl; `--status` counts the ones still unjudged inside the window.
"""

from __future__ import annotations

import functools
import json
import os
from typing import NamedTuple

import zuvo_bill_config as C
import zuvo_bill_state as S
from zuvo_bill_judge import Item
from zuvo_review_ledger import iter_jsonl, project_key, read_rows, remote_roots

API = 3


class Unresolved(NamedTuple):
    item: Item
    reason: str    # project-gone | not-a-checkout | no-checkout | no-project
    detail: str


def is_checkout(path: str) -> bool:
    """A git checkout: a directory holding `.git` (a directory, or the file a linked worktree has)."""
    return os.path.isdir(path) and os.path.exists(os.path.join(path, ".git"))


class Resolver:
    """One per tick: the mirrored ledgers are read at most once, and only when a bare name needs them."""

    def __init__(self) -> None:
        self._mirrored: dict[str, list[str]] | None = None

    def resolve(self, project: str) -> tuple[str | None, str, str]:
        """(the checkout to record from, "", "") or (None, reason, detail)."""
        if os.path.isabs(project):
            if is_checkout(project):
                return project, "", ""
            return None, ("not-a-checkout" if os.path.isdir(project) else "project-gone"), project
        name = project_key(project)
        if name is None:
            return None, "no-project", ""
        where = self.checkout_for(name)
        return (where, "", "") if where else (None, "no-checkout", name)

    def checkout_for(self, name: str) -> str | None:
        dev = os.path.join(os.path.expanduser("~"), "DEV", name)
        if is_checkout(dev):
            return dev
        return next((p for p in self._mirrored_paths().get(name, []) if is_checkout(p)), None)

    def _mirrored_paths(self) -> dict[str, list[str]]:
        """basename -> the absolute project paths the mirrored ledgers carry, in first-seen order. A mirror
        that cannot be read or parsed is passed over: it never stops the tick."""
        if self._mirrored is None:
            found: dict[str, list[str]] = {}
            for ledger in remote_roots("adversarial-findings.log"):
                try:
                    for r in read_rows(ledger):
                        path = r.project.strip().rstrip("/") if isinstance(r.project, str) else ""
                        key = project_key(path) if os.path.isabs(path) else None
                        if key and path not in found.setdefault(key, []):
                            found[key].append(path)
                except (OSError, ValueError):
                    continue
            self._mirrored = found
        return self._mirrored


def split(queue: list[Item]) -> tuple[list[Item], list[Unresolved]]:
    """(the reviews to judge, each with its project replaced by the checkout it resolved to; the rest).
    The judged-set join keys on the basename, which the resolved checkout keeps."""
    resolver, keep, skip = Resolver(), [], []
    for ts, run, project, rows in queue:
        where, reason, detail = resolver.resolve(project)
        if where is None:
            skip.append(Unresolved((ts, run, project, rows), reason, detail))
        else:
            keep.append((ts, run, where, rows))
    return keep, skip


def set_aside(unresolved: list[Unresolved]) -> None:
    """One unrecordable.jsonl row per run (it is seen again on every tick), never a done-mark: each tick
    checks the run again until it resolves or leaves the window."""
    path = os.path.join(C.bill_data(), "unrecordable.jsonl")
    try:
        logged = {r["run"] for r in iter_jsonl(path) if isinstance(r.get("run"), str)}
    except OSError:
        logged = set()
    for (review_ts, run, project, rows), reason, detail in unresolved:
        if run in logged:
            continue
        line = json.dumps({"ts": C.stamp(C.now()), "review_ts": review_ts, "run": run, "project": project,
                           "findings": len(rows), "reason": reason, "detail": detail}, ensure_ascii=False)
        S.persist("unrecordable.jsonl", functools.partial(C.append, path, line))
